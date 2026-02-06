# Camera Access App

A sample iOS application demonstrating integration with Meta Wearables Device Access Toolkit. This app showcases streaming video from Meta AI glasses, capturing photos, and managing connection states.

## Features

- Connect to Meta AI glasses
- Stream camera feed from the device
- Capture photos from glasses
- Share captured photos
- **v1.0: Gemini Live AI assistant** - real-time voice + vision conversation through glasses
- **v2.0: OpenClaw integration** - agentic actions via Gemini Live tool-calling (web search, messaging, task delegation)

## Prerequisites

- iOS 17.0+
- Xcode 14.0+
- Swift 5.0+
- Meta Wearables Device Access Toolkit (included as a dependency)
- A Meta AI glasses device for testing (optional for development)
- Gemini API key (for AI features)
- OpenClaw gateway running (for v2.0 agentic features)

## Building the app

### Using Xcode

1. Clone this repository
1. Open the project in Xcode
1. Select your target device
1. Click the "Build" button or press `Cmd+B` to build the project
1. To run the app, click the "Run" button or press `Cmd+R`

## Running the app

1. Turn 'Developer Mode' on in the Meta AI app.
1. Launch the app.
1. Press the "Connect" button to complete app registration.
1. Once connected, the camera stream from the device will be displayed
1. Use the on-screen controls to:
   - Capture photos
   - View and save captured photos
   - Disconnect from the device
   - Tap the AI button for Gemini Live voice conversation

## Architecture

### v1.0 - Gemini Live (current)

```
Meta Ray-Ban Glasses
       |
       | camera frames (24fps) + mic audio
       v
iOS App (CameraAccess)
       |
       | video (1fps JPEG) + audio (PCM 16kHz)
       v
Gemini Live API (WebSocket)
       |
       | audio response (PCM 24kHz) + transcription
       v
iOS App -> Speaker + Transcript UI
```

- Direct WebSocket to `wss://generativelanguage.googleapis.com/ws/.../BidiGenerateContent`
- Model: `gemini-2.5-flash-native-audio-preview-12-2025`
- End-to-end native audio (not STT-first)
- Video frames streamed at ~1fps for vision context
- Audio: PCM 16kHz mono input, PCM 24kHz mono output
- Session limit: 2 min (audio+video), 15 min (audio-only)

### v2.0 - OpenClaw Integration (current)

```
Meta Ray-Ban Glasses
       |
       | camera frames (24fps) + mic audio
       v
iOS App (CameraAccess)
       |
       | video (1fps JPEG) + audio (PCM 16kHz)
       v
Gemini Live API (WebSocket)
  - Real-time voice + vision
  - Tool declarations in setup message
       |
       | toolCall { functionCalls: [{id, name, args}] }
       v
iOS App (ToolCallRouter)
  - Routes tool calls to OpenClaw via HTTP
  - Tracks in-flight calls for cancellation
       |
       | web_search -> POST /tools/invoke (sync, ~5s)
       | delegate_task, send_message -> POST /v1/chat/completions (sync, up to 120s)
       v
OpenClaw Gateway (LAN IP:18789)
  - 56+ skills, all connected channels
  - Returns result synchronously
       |
       v
iOS App -> sendToolResponse back to Gemini -> Gemini speaks result
```

**Key concept:** Gemini Live = real-time frontdesk agent (voice + vision), OpenClaw = gateway agent (actions on everything).

**Tools available:**
| Tool | Type | Description |
|------|------|-------------|
| `web_search` | Blocking | Search the web via Brave Search, returns results immediately |
| `delegate_task` | NON_BLOCKING | Complex/long-running tasks (research, analysis, drafts) |
| `send_message` | NON_BLOCKING | Send messages via WhatsApp, Telegram, iMessage, Slack, etc. |

## v2.0 Setup (OpenClaw)

### Prerequisites

1. OpenClaw running on your Mac with gateway enabled
2. iOS device and Mac on the same local network

### OpenClaw Configuration

In `~/.openclaw/openclaw.json`, ensure these settings:

```json
{
  "gateway": {
    "port": 18789,
    "bind": "lan",
    "auth": { "mode": "token", "token": "YOUR_GATEWAY_TOKEN" },
    "http": {
      "endpoints": {
        "chatCompletions": { "enabled": true }
      }
    }
  },
  "hooks": {
    "enabled": true,
    "token": "YOUR_HOOK_TOKEN"
  },
  "tools": {
    "web": {
      "search": { "enabled": true, "apiKey": "YOUR_BRAVE_API_KEY" }
    }
  }
}
```

Key points:
- `bind: "lan"` exposes the gateway on `0.0.0.0` so the iPhone can reach it
- `chatCompletions.enabled: true` enables the synchronous `/v1/chat/completions` endpoint (disabled by default)
- Brave Search API key is needed for `web_search` tool
- Start/restart gateway: `openclaw gateway restart`

### iOS App Configuration

In [GeminiConfig.swift](samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift), update:

```swift
static let openClawHost = "http://YOUR_MAC_LAN_IP"  // e.g. "http://192.168.0.117"
static let openClawPort = 18789
static let openClawGatewayToken = "YOUR_GATEWAY_TOKEN"  // must match gateway.auth.token
```

`Info.plist` already has `NSAllowsLocalNetworking = true` for HTTP to local network IPs.

## OpenClaw Gateway API (as used)

### POST /v1/chat/completions (agent tasks)

Used for `delegate_task` and `send_message`. Synchronous -- waits for the OpenClaw agent to complete and returns the full result.

```
POST http://<mac-ip>:18789/v1/chat/completions
Authorization: Bearer <gateway-token>
Content-Type: application/json

{
  "model": "openclaw",
  "messages": [{ "role": "user", "content": "Research the best coffee shops in Boulder" }],
  "stream": false
}
```

Returns OpenAI-compatible response: `{ "choices": [{ "message": { "content": "..." } }] }`

### POST /tools/invoke (single tool)

Used for `web_search`. Synchronous, returns the tool result directly.

```
POST http://<mac-ip>:18789/tools/invoke
Authorization: Bearer <gateway-token>
Content-Type: application/json

{
  "tool": "web_search",
  "action": "json",
  "args": { "query": "weather in SF" },
  "sessionKey": "glass:default"
}
```

## Gemini Live Tool Calling

Tools are declared in the WebSocket setup message. The model sends `toolCall` messages (top-level, not inside `serverContent`), the app routes them to OpenClaw, and sends back `toolResponse`.

**Blocking vs Non-blocking:**
- Default (blocking): Gemini pauses until tool responds (`web_search`)
- `"behavior": "NON_BLOCKING"`: Gemini continues talking while tool executes (`delegate_task`, `send_message`)

**Note:** NON_BLOCKING has a known issue where Gemini may speculate before tool results arrive.

## Implementation Status

### Phase 1: Basic tool bridge -- COMPLETE
1. Tool declarations in Gemini setup message
2. `toolCall` / `toolCallCancellation` message handling in GeminiLiveService
3. OpenClawBridge HTTP client (two endpoints: /v1/chat/completions + /tools/invoke)
4. ToolCallRouter dispatches tool calls and sends toolResponse back to Gemini
5. Three tools working: `web_search`, `delegate_task`, `send_message`
6. Tool call status UI overlay (spinner, checkmark, error states)

### Phase 2: Rich tool set -- PLANNED
- Add more specific tool declarations (reminders, notes, smart home, etc.)
- Proactive tool use (Gemini decides when to use tools based on context)

### Phase 3: Session continuity -- PLANNED
- Gemini session resumption for longer conversations
- Consistent OpenClaw sessionKey for multi-turn context

### Key Files

| File | Purpose |
|------|---------|
| `Gemini/GeminiConfig.swift` | API keys, model config, system instruction, OpenClaw config |
| `Gemini/GeminiLiveService.swift` | WebSocket client, message handling, tool call callbacks |
| `Gemini/AudioManager.swift` | Audio capture (Float32 tap, 4096 buffer, 100ms chunks) + playback |
| `Gemini/GeminiSessionViewModel.swift` | Session orchestration, transcript state, tool call wiring |
| `OpenClaw/ToolCallModels.swift` | Data types: GeminiFunctionCall, ToolResult, ToolCallStatus, ToolDeclarations |
| `OpenClaw/OpenClawBridge.swift` | HTTP client for OpenClaw gateway (/v1/chat/completions + /tools/invoke) |
| `OpenClaw/ToolCallRouter.swift` | Routes Gemini tool calls to OpenClaw, manages in-flight tasks |
| `Views/Components/GeminiOverlayView.swift` | Transcript UI, ToolCallStatusView, speaking indicator |
| `Views/StreamView.swift` | Main streaming view |

## Troubleshooting

For issues related to the Meta Wearables Device Access Toolkit, please refer to the [developer documentation](https://wearables.developer.meta.com/docs/develop/) or visit our [discussions forum](https://github.com/facebook/meta-wearables-dat-ios/discussions)

## License

This source code is licensed under the license found in the LICENSE file in the root directory of this source tree.
