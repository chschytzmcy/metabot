# MetaBot Go 重写设计文档

> 状态：Draft | 日期：2026-04-10 | 版本：v0.1

## 1. 背景与目标

### 1.1 为什么要重写

当前 MetaBot 是 TypeScript (Node.js) 项目，存在以下痛点：

| 问题                                     | 影响                          |
| ---------------------------------------- | ----------------------------- |
| 部署需要 Node.js 运行时 + npm install    | 环境复杂，Docker 镜像 ~200MB  |
| `better-sqlite3` 需编译 C++ native addon | 跨平台部署困难                |
| 无法编译为单二进制                       | 需 PM2 管理，无法原生 systemd |
| 运行时内存 ~200-300MB                    | 资源占用高                    |

### 1.2 重写目标

- **单二进制部署** — `go build` 产出可直接 `scp` 到服务器运行
- **开机自启动** — 原生 systemd service，无需 PM2
- **只支持飞书** — 移除 Telegram / 微信 / Voice / RTC 等通道
- **保持 API 兼容** — Web UI 的 WebSocket 和 REST API 保持一致，前端不动

### 1.3 可行性结论

**可行度 90%+**。所有 18 个 npm 依赖都有 Go 替代方案。最关键的 `@anthropic-ai/claude-agent-sdk` 不需要 Go 版本 —— Claude 原生二进制直接支持 JSON 流 over stdin/stdout，Go 用 `os/exec` 即可完整替代。

## 2. 架构设计

### 2.1 整体架构

```
┌──────────────────────────────────────────────────────────┐
│  metabot (单二进制)                                       │
│                                                          │
│  ┌──────────┐   ┌───────────────┐   ┌────────────────┐  │
│  │ Feishu   │   │  HTTP Server  │   │  Scheduler     │  │
│  │ WSClient │   │  :9100        │   │  (cron)        │  │
│  └────┬─────┘   ├───────────────┤   └───────┬────────┘  │
│       │         │ /api/*        │           │           │
│       │         │ /ws (WebSocket│           │           │
│       │         │ /web/ (static)│           │           │
│       │         └───────┬───────┘           │           │
│       │                 │                   │           │
│       ▼                 ▼                   ▼           │
│  ┌─────────────────────────────────────────────────┐    │
│  │                  MessageBridge                   │    │
│  │  命令路由 · 消息队列 · 会话管理 · 限流           │    │
│  └──────────────────────┬──────────────────────────┘    │
│                         │                               │
│       ┌─────────────────┼─────────────────┐             │
│       ▼                 ▼                 ▼             │
│  ┌──────────┐   ┌──────────────┐   ┌──────────────┐    │
│  │ Claude   │   │ MetaMemory   │   │ PeerManager  │    │
│  │ Executor │   │ (SQLite)     │   │ (HTTP)       │    │
│  └──────────┘   └──────────────┘   └──────────────┘    │
│       │                                                 │
│       ▼                                                 │
│  claude binary (stdin/stdout JSON stream)                │
└──────────────────────────────────────────────────────────┘
```

### 2.2 目录结构

```
metabot-go/
├── main.go                     # 入口：配置加载、服务启动、graceful shutdown
├── config/
│   ├── config.go               # 配置结构体 + 加载逻辑
│   └── config_test.go
├── feishu/
│   ├── wsclient.go             # 飞书 WebSocket 长连接
│   ├── event_handler.go        # 消息解析、@mention 过滤
│   ├── card_builder.go         # 交互卡片 JSON 构建
│   ├── message_sender.go       # 飞书 API（发消息、上传文件、图片）
│   └── doc_reader.go           # 飞书文档读取 → Markdown
├── bridge/
│   ├── message_bridge.go       # 核心编排器
│   ├── command_handler.go      # /reset, /stop, /help 等命令
│   ├── rate_limiter.go         # 卡片更新限流（1.5s 合并）
│   ├── outputs_manager.go      # 输出文件管理
│   └── chat_subscriptions.go   # 订阅管理（WS 推送）
├── claude/
│   ├── executor.go             # Claude 二进制 spawn + JSON 流通信
│   ├── stream_processor.go     # SDK 消息 → CardState 转换
│   ├── session_manager.go      # 会话管理（内存 + 持久化）
│   └── process.go              # 进程管理（spawn, stdin/stdout pipe）
├── memory/
│   ├── storage.go              # SQLite 存储（文档、FTS5 搜索）
│   ├── server.go               # 嵌入式 HTTP 服务（:8100）
│   └── events.go               # 文档变更事件
├── sync/
│   ├── doc_sync.go             # MetaMemory → 飞书 Wiki 同步
│   ├── sync_store.go           # 同步映射持久化（SQLite）
│   └── markdown_to_blocks.go   # Markdown → 飞书 Block 转换
├── api/
│   ├── server.go               # HTTP 服务（:9100）
│   ├── routes.go               # API 路由注册
│   ├── bot_registry.go         # Bot 注册表
│   ├── peer_manager.go         # 跨实例发现与转发
│   ├── ws_server.go            # WebSocket 服务
│   └── intent_router.go        # 意图路由（可选）
├── scheduler/
│   └── scheduler.go            # Cron 定时任务
├── web/                        # 前端（不动，沿用现有 React SPA）
│   └── dist/                   # 构建产物，嵌入二进制或同目录
├── go.mod
├── go.sum
├── Makefile                    # build / install / systemd
└── metabot.service             # systemd unit 文件
```

## 3. 核心模块设计

### 3.1 Claude Executor — 直接与 claude 二进制通信

这是重写的核心。不需要官方 SDK，直接 spawn `claude` 原生二进制。

#### 3.1.1 协议

Claude 二进制原生支持 JSON 流通信：

```bash
# 启动参数
claude \
  --output-format stream-json \    # 输出：换行分隔 JSON
  --input-format stream-json \     # 输入：换行分隔 JSON
  --print \                        # 非交互模式
  --verbose \                      # 详细输出（工具调用等）
  --max-turns 50 \                 # 最大轮次
  --permission-mode bypassPermissions \  # 绕过权限
  --allow-dangerously-skip-permissions

# 可选参数
  --resume <sessionId>             # 恢复会话
  --model <model>                  # 指定模型
  --max-budget-usd <float>         # 预算限制
  --allowed-tools Read,Edit,Write  # 工具白名单
  --mcp-config <json>              # MCP 服务器配置
```

#### 3.1.2 消息格式

**输入（用户消息）：**

```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": "用户输入的文本"
  },
  "parent_tool_use_id": null,
  "session_id": ""
}
```

**输出事件流（换行分隔）：**

```json
{"type":"system","subtype":"init","session_id":"...","tools":[...],"model":"..."}
{"type":"assistant","message":{"content":[{"type":"text","text":"..."}]},...}
{"type":"result","subtype":"success","total_cost_usd":0.15,"session_id":"..."}
```

#### 3.1.3 Go 实现

```go
package claude

import (
    "bufio"
    "context"
    "encoding/json"
    "io"
    "os/exec"
    "syscall"
)

type Process struct {
    cmd    *exec.Cmd
    stdin  io.WriteCloser
    stdout *bufio.Scanner
    cancel context.CancelFunc
}

type ProcessConfig struct {
    CWD            string
    SessionID      string // 空字符串 = 新建会话
    MaxTurns       int
    MaxBudgetUSD   float64
    Model          string
    AllowedTools   []string
    MCPConfig      string // JSON string
    SystemPrompt   string // 追加到系统提示
}

func StartProcess(ctx context.Context, cfg ProcessConfig) (*Process, error) {
    args := []string{
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--print", "--verbose",
        "--permission-mode", "bypassPermissions",
        "--allow-dangerously-skip-permissions",
    }

    if cfg.SessionID != "" {
        args = append(args, "--resume", cfg.SessionID)
    }
    if cfg.MaxTurns > 0 {
        args = append(args, "--max-turns", fmt.Sprintf("%d", cfg.MaxTurns))
    }
    if cfg.MaxBudgetUSD > 0 {
        args = append(args, "--max-budget-usd", fmt.Sprintf("%.2f", cfg.MaxBudgetUSD))
    }
    if cfg.Model != "" {
        args = append(args, "--model", cfg.Model)
    }
    if len(cfg.AllowedTools) > 0 {
        args = append(args, "--allowed-tools", strings.Join(cfg.AllowedTools, ","))
    }
    if cfg.MCPConfig != "" {
        args = append(args, "--mcp-config", cfg.MCPConfig)
    }

    ctx, cancel := context.WithCancel(ctx)
    cmd := exec.CommandContext(ctx, "claude", args...)
    cmd.Dir = cfg.CWD
    cmd.Env = buildEnv() // 过滤 CLAUDE* 环境变量，注入 ANTHROPIC_API_KEY

    stdin, _ := cmd.StdinPipe()
    stdout, _ := cmd.StdoutPipe()

    if err := cmd.Start(); err != nil {
        cancel()
        return nil, fmt.Errorf("spawn claude: %w", err)
    }

    return &Process{
        cmd:    cmd,
        stdin:  stdin,
        stdout: bufio.NewScanner(stdout),
        cancel: cancel,
    }, nil
}

func (p *Process) SendMessage(msg any) error {
    data, err := json.Marshal(msg)
    if err != nil {
        return err
    }
    _, err = p.stdin.Write(append(data, '\n'))
    return err
}

func (p *Process) ReadMessage() (map[string]any, error) {
    if !p.stdout.Scan() {
        return nil, io.EOF
    }
    var msg map[string]any
    if err := json.Unmarshal(p.stdout.Bytes(), &msg); err != nil {
        return nil, err
    }
    return msg, nil
}

func (p *Process) Close() {
    p.cancel()
    p.cmd.Process.Signal(syscall.SIGTERM)
}
```

#### 3.1.4 多轮对话

保持 stdin 打开，持续写入新消息即可实现多轮：

```go
// 首轮
p.Send(UserMessage{Type: "user", Message: Message{Role: "user", Content: "hello"}})

// 消费响应流
for {
    msg, err := p.ReadMessage()
    if err == io.EOF { break }
    if msg["type"] == "result" { break } // 一轮结束
    // 处理 assistant 消息、工具调用等...
}

// 后续轮次 — stdin 仍然打开，直接写入
p.Send(UserMessage{Type: "user", Message: Message{Role: "user", Content: "follow up"}})
```

### 3.2 Message Bridge — 核心编排器

```go
type MessageBridge struct {
    logger         *slog.Logger
    botRegistry    *BotRegistry
    sessionManager *SessionManager
    claudeExecutor *ClaudeExecutor
    rateLimiter    *RateLimiter
    outputsManager *OutputsManager

    mu          sync.Mutex
    runningTasks map[string]*RunningTask // chatId → task
    queues       map[string][]*IncomingMessage
}

func (b *MessageBridge) HandleMessage(ctx context.Context, msg *IncomingMessage) error {
    // 1. 命令检测 (/reset, /stop, /help, /memory, /sync)
    if handled := b.handleCommand(msg); handled {
        return nil
    }

    // 2. 加入队列（每个 chatId 最多排队 5 条）
    b.enqueue(msg)

    // 3. 如果当前无运行任务，启动执行
    b.mu.Lock()
    if _, running := b.runningTasks[msg.ChatID]; !running {
        b.mu.Unlock()
        go b.processQueue(ctx, msg.ChatID)
    } else {
        b.mu.Unlock()
    }

    return nil
}
```

### 3.3 飞书集成

使用官方 Go SDK `github.com/larksuite/oapi-sdk-go/v3`：

```go
import larkim "github.com/larksuite/oapi-sdk-go/v3/service/im/v1"

type FeishuSender struct {
    client *lark.Client
}

// 发送交互卡片
func (s *FeishuSender) UpdateCard(ctx context.Context, messageID string, card CardState) error {
    cardJSON := BuildCard(card)
    resp, err := s.client.Im.Message.Patch(ctx, larkim.NewPatchMessageReqBuilder().
        MessageId(messageID).
        Body(larkim.NewPatchMessageReqBodyBuilder().
            Content(string(cardJSON)).
            Build()).
        Build())
    // ...
}

// 上传图片
func (s *FeishuSender) UploadImage(ctx context.Context, filePath string) (string, error) {
    // im.v1.image.create
}

// 上传文件
func (s *FeishuSender) UploadFile(ctx context.Context, filePath string) (string, error) {
    // im.v1.file.create
}
```

飞书 WebSocket 连接使用 `github.com/larksuite/oapi-sdk-go/v3/ws`（官方已支持）。

### 3.4 会话管理

```go
type SessionManager struct {
    mu       sync.RWMutex
    sessions map[string]*Session // chatId → session
    db       *sql.DB             // 持久化
    maxAge   time.Duration       // 24h TTL
}

type Session struct {
    ChatID     string
    ClaudeSID  string    // Claude session ID（用于 --resume）
    CWD        string    // 工作目录
    CreatedAt  time.Time
    LastUsedAt time.Time
}

func (m *SessionManager) GetOrCreate(chatID string, defaultCWD string) *Session {
    m.mu.RLock()
    s, ok := m.sessions[chatID]
    m.mu.RUnlock()

    if ok && time.Since(s.LastUsedAt) < m.maxAge {
        return s
    }

    // 新建或从 DB 恢复
    s = &Session{
        ChatID:    chatID,
        CWD:       defaultCWD,
        CreatedAt: time.Now(),
    }
    m.mu.Lock()
    m.sessions[chatID] = s
    m.mu.Unlock()
    return s
}
```

### 3.5 限流器（卡片更新合并）

```go
type RateLimiter struct {
    mu        sync.Mutex
    interval  time.Duration // 1.5s
    pending   map[string]*PendingUpdate
    lastSent  map[string]time.Time
}

type PendingUpdate struct {
    Card     CardState
    ChatID   string
    Callback func() error
}

func (r *RateLimiter) Submit(chatID string, card CardState, send func() error) {
    r.mu.Lock()
    defer r.mu.Unlock()

    r.pending[chatID] = &PendingUpdate{Card: card, ChatID: chatID, Callback: send}

    if last, ok := r.lastSent[chatID]; ok && time.Since(last) < r.interval {
        // 还在冷却期，schedule 延迟发送
        time.AfterFunc(r.interval-time.Since(last), func() {
            r.flush(chatID)
        })
        return
    }

    // 立即发送
    r.flush(chatID)
}
```

### 3.6 MetaMemory（SQLite + FTS5）

```go
type MemoryStorage struct {
    db *sql.DB
}

func NewMemoryStorage(dbPath string) (*MemoryStorage, error) {
    db, err := sql.Open("sqlite", dbPath)
    // 创建表：documents (id, path, title, content, hash, updated_at)
    // 创建 FTS5 索引：documents_fts
    return &MemoryStorage{db: db}, nil
}

func (s *MemoryStorage) Search(query string, limit int) ([]Document, error) {
    rows, err := s.db.Query(`
        SELECT id, path, title, snippet(documents_fts, 2, '>>>', '<<<', '...', 20) as snippet
        FROM documents_fts WHERE documents_fts MATCH ? ORDER BY rank LIMIT ?
    `, query, limit)
    // ...
}
```

### 3.7 HTTP API

保持与现有 TS 版本相同的路由，前端无需修改：

| Method | Path            | 说明           |
| ------ | --------------- | -------------- |
| POST   | `/api/talk`     | Agent 间通信   |
| GET    | `/api/talk/:id` | 异步任务状态   |
| GET    | `/api/bots`     | Bot 列表       |
| GET    | `/api/peers`    | Peer 状态      |
| POST   | `/api/schedule` | 创建定时任务   |
| GET    | `/api/sync`     | Wiki 同步状态  |
| POST   | `/api/sync`     | 触发 Wiki 同步 |
| GET    | `/api/memory/*` | MetaMemory API |
| GET    | `/ws`           | WebSocket 升级 |
| GET    | `/web/*`        | 前端静态文件   |

## 4. 依赖对照表

| TS 依赖                          | 功能          | Go 替代                                  | 安装方式            |
| -------------------------------- | ------------- | ---------------------------------------- | ------------------- |
| `@anthropic-ai/claude-agent-sdk` | Claude 通信   | **不需要** — 直接 spawn claude 二进制    | 系统安装 claude CLI |
| `@anthropic-ai/sdk`              | Anthropic API | `github.com/anthropics/anthropic-sdk-go` | go get              |
| `@larksuiteoapi/node-sdk`        | 飞书 API      | `github.com/larksuite/oapi-sdk-go/v3`    | go get              |
| `better-sqlite3`                 | SQLite        | `modernc.org/sqlite` (纯 Go)             | go get              |
| `ws`                             | WebSocket     | `github.com/gorilla/websocket`           | go get              |
| `pino`                           | 日志          | `log/slog` (标准库)                      | 无需安装            |
| `cron-parser`                    | Cron 解析     | `github.com/robfig/cron/v3`              | go get              |
| `dotenv`                         | .env 加载     | `github.com/joho/godotenv`               | go get              |
| `xlsx`                           | Excel         | `github.com/xuri/excelize/v2`            | go get              |
| `openai`                         | OpenAI API    | `github.com/sashabaranov/go-openai`      | go get              |
| `mammoth`                        | DOCX 解析     | `github.com/nguyenthenguyen/docx`        | go get              |
| `undici`                         | HTTP 客户端   | `net/http` (标准库)                      | 无需安装            |
| `https-proxy-agent`              | HTTP 代理     | `net/http` (标准库)                      | 无需安装            |
| `node-edge-tts`                  | Edge TTS      | 不需要（无语音）                         | —                   |
| `@volcengine/openapi`            | 火山引擎 TTS  | 不需要（无语音）                         | —                   |
| `grammy`                         | Telegram      | 不需要                                   | —                   |

## 5. 部署设计

### 5.1 编译

```makefile
# Makefile
.PHONY: build clean install

BINARY=metabot
VERSION=$(shell git describe --tags --always --dirty)

build:
	CGO_ENABLED=0 go build -ldflags="-s -w -X main.version=$(VERSION)" -o $(BINARY) .

build-linux:
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w" -o $(BINARY)-linux-amd64 .

clean:
	rm -f $(BINARY) $(BINARY)-linux-amd64

install: build
	cp $(BINARY) /usr/local/bin/
	cp metabot.service /etc/systemd/system/
	systemctl daemon-reload
	systemctl enable metabot
```

### 5.2 systemd Service

```ini
# metabot.service
[Unit]
Description=MetaBot — Feishu to Claude Code Bridge
After=network.target

[Service]
Type=simple
User=metabot
Group=metabot
WorkingDirectory=/opt/metabot
ExecStart=/usr/local/bin/metabot
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

EnvironmentFile=/opt/metabot/.env

# 安全加固
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/metabot /tmp/metabot-outputs
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### 5.3 运行产出

```
-rwxr-xr-x  1 metabot metabot  22M  metabot    # 单二进制
-rw-r--r--  1 metabot metabot 256   .env        # 配置
-rw-r--r--  1 metabot metabot 2.1K  bots.json   # Bot 配置
drwxr-xr-x  2 metabot metabot 4.0K  web/       # 前端静态文件
```

## 6. 工作量估算

### 6.1 按模块拆分

| 模块                                                   | 预估行数   | 难度 | 预估时间   |
| ------------------------------------------------------ | ---------- | ---- | ---------- |
| **main.go + config**                                   | 300        | 🟢   | 0.5 天     |
| **claude/ (executor + process + stream)**              | 800        | 🟡   | 2 天       |
| **bridge/ (message_bridge + commands + rate_limiter)** | 1,500      | 🔴   | 3 天       |
| **feishu/ (wsclient + event + card + sender)**         | 1,000      | 🟡   | 2 天       |
| **feishu/ (doc_reader)**                               | 200        | 🟢   | 0.5 天     |
| **api/ (server + routes + ws + registry + peer)**      | 1,200      | 🟡   | 2 天       |
| **memory/ (storage + server)**                         | 800        | 🟢   | 1 天       |
| **sync/ (doc_sync + markdown_to_blocks)**              | 900        | 🟡   | 1.5 天     |
| **scheduler/**                                         | 300        | 🟢   | 0.5 天     |
| **Makefile + systemd + 测试**                          | 500        | 🟢   | 1 天       |
| **总计**                                               | **~7,500** | —    | **~14 天** |

### 6.2 建议实施顺序

```
Phase 1 (MVP, 5 天)：
  1. config + main.go
  2. claude/ (executor — spawn + JSON 流)
  3. bridge/ (message_bridge 核心)
  4. feishu/ (event_handler + message_sender + card_builder)
  → 飞书消息 → Claude 执行 → 卡片回复，跑通核心链路

Phase 2 (完善, 4 天)：
  5. api/ (HTTP server + WebSocket + routes)
  6. bridge/ (commands: /reset, /stop, /help)
  7. feishu/ (doc_reader)
  → Web UI 可用，命令系统完整

Phase 3 (高级功能, 5 天)：
  8. memory/ (MetaMemory SQLite + HTTP)
  9. sync/ (Wiki 同步)
  10. scheduler/ (定时任务)
  11. peer_manager/ (跨实例)
  12. Makefile + systemd + 测试
  → 功能完整，可生产部署
```

## 7. 风险与缓解

| 风险                                            | 影响 | 缓解措施                                      |
| ----------------------------------------------- | ---- | --------------------------------------------- |
| Claude 二进制 JSON 流协议有未文档化的 edge case | 中   | 先用 Go 写一个 protocol fuzzer 对比 TS 版行为 |
| 飞书 WebSocket Go SDK 不如 TS 版成熟            | 中   | 实测后可能需要补一些 wrapper                  |
| Markdown → 飞书 Blocks 移植工作量大             | 低   | 纯逻辑移植，可先简化（只支持核心 block 类型） |
| Wiki 同步的飞书 API 调用复杂                    | 低   | 可延后，Phase 3 实现                          |

## 8. 不重写的部分

| 模块                                    | 原因                                               |
| --------------------------------------- | -------------------------------------------------- |
| **Web 前端** (`web/`)                   | React SPA 不动，Go 只提供静态文件服务 + WebSocket  |
| **Claude Skills** (`~/.claude/skills/`) | 运行时由 claude 二进制自行加载，与后端语言无关     |
| **MCP 服务器**                          | Claude 二进制自行连接，Go 只传 `--mcp-config` 参数 |

## 9. 验收标准

- [ ] 单二进制 `metabot` 可在 Linux amd64 运行
- [ ] 飞书消息 → Claude 执行 → 流式卡片更新，全链路跑通
- [ ] 支持多轮对话（session resume）
- [ ] 支持 `/reset`、`/stop`、`/help`、`/memory`、`/sync` 命令
- [ ] Web UI 可用（WebSocket 流式 + 静态文件）
- [ ] MetaMemory 文档读写 + 搜索可用
- [ ] Wiki 同步可用
- [ ] systemd 开机自启动
- [ ] 内存占用 < 100MB
- [ ] 启动时间 < 500ms
