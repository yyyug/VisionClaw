# Camera Access App

A sample iOS application demonstrating integration with Meta Wearables Device Access Toolkit. This app showcases streaming video from Meta AI glasses, capturing photos, and managing connection states.

## Features

- Connect to Meta AI glasses
- Stream camera feed from the device
- Capture photos from glasses
- Share captured photos
- **v1.0: Gemini Live AI assistant** - real-time voice + vision conversation through glasses
- **v2.0 (planned): OpenClaw integration** - agentic actions via Gemini Live tool-calling

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

### v2.0 - OpenClaw Integration (planned)

```
Meta Ray-Ban Glasses
       |
       | camera + mic
       v
iOS App (CameraAccess)
       |
       | audio + video frames
       v
Gemini Live API (WebSocket)
  - Real-time voice conversation
  - Sees through glasses camera
  - Has OpenClaw tools declared as function declarations
       |
       | toolCall (e.g. send_message, web_search, add_reminder)
       v
iOS App (Bridge Layer)
  - Intercepts toolCall from Gemini
  - Forwards to OpenClaw Gateway via HTTP
       |
       | POST /hooks/agent
       v
OpenClaw Gateway (localhost:18789)
  - Processes task (messaging, web, smart home, etc.)
  - Has access to 56+ skills and all connected channels
  - Returns result
       |
       | result
       v
iOS App (Bridge Layer)
  - Sends BidiGenerateContentToolResponse back to Gemini
       |
       | toolResponse
       v
Gemini Live API
  - Speaks the result to user through glasses speaker
```

**Key concept:** Gemini Live = real-time frontdesk agent (voice + vision), OpenClaw = gateway agent (async actions on everything).

## v2.0 Research & Design

### Gemini Live Tool Calling

Gemini Live API supports function calling via WebSocket. All functions must be declared in the `BidiGenerateContentSetup` message:

```json
{
  "setup": {
    "model": "models/gemini-2.5-flash-native-audio-preview-12-2025",
    "tools": [{
      "functionDeclarations": [
        {
          "name": "send_message",
          "description": "Send a message to someone via messaging app",
          "parameters": {
            "type": "object",
            "properties": {
              "to": { "type": "string", "description": "Recipient name or identifier" },
              "message": { "type": "string", "description": "Message content" },
              "channel": { "type": "string", "enum": ["whatsapp", "telegram", "imessage", "slack", "discord"] }
            },
            "required": ["to", "message"]
          },
          "behavior": "NON_BLOCKING"
        },
        {
          "name": "web_search",
          "description": "Search the web for information",
          "parameters": {
            "type": "object",
            "properties": {
              "query": { "type": "string", "description": "Search query" }
            },
            "required": ["query"]
          }
        },
        {
          "name": "delegate_task",
          "description": "Delegate a complex or long-running task to the personal AI assistant",
          "parameters": {
            "type": "object",
            "properties": {
              "task": { "type": "string", "description": "Task description" },
              "deliver": { "type": "boolean", "description": "Whether to send result to a chat channel" },
              "channel": { "type": "string", "description": "Channel to deliver result to" }
            },
            "required": ["task"]
          },
          "behavior": "NON_BLOCKING"
        }
      ]
    }]
  }
}
```

**Tool call flow:**
1. Model sends `toolCall` message: `{ "toolCall": { "functionCalls": [{ "id": "call-123", "name": "send_message", "args": { "to": "Mom", "message": "On my way!" } }] } }`
2. iOS app intercepts, forwards to OpenClaw
3. iOS app sends back `toolResponse`: `{ "toolResponse": { "functionResponses": [{ "id": "call-123", "response": { "result": "Message sent" } }] } }`
4. Gemini speaks the result

**Blocking vs Non-blocking:**
- Default (blocking): Gemini pauses until tool responds
- `"behavior": "NON_BLOCKING"`: Gemini continues talking ("Let me work on that...")
  - `INTERRUPT` scheduling: stop current speech, speak result immediately
  - `WHEN_IDLE` scheduling: speak result after current response
  - `SILENT` scheduling: process result silently

**Note:** NON_BLOCKING has a known issue where Gemini may hallucinate/speculate before tool results arrive. Use blocking for critical actions, NON_BLOCKING for background tasks.

### OpenClaw Gateway API

OpenClaw exposes three integration points:

#### HTTP Webhook (recommended for iOS)

```
POST http://localhost:18789/hooks/agent
Authorization: Bearer <hook-token>
Content-Type: application/json

{
  "message": "Send a WhatsApp message to Mom saying I'm on my way",
  "name": "Glass Voice",
  "sessionKey": "glass:default",
  "wakeMode": "now",
  "deliver": true,
  "channel": "last",
  "timeoutSeconds": 120
}
```

Returns `202` with `{ "runId": "..." }` (async).

**Configuration** (in `~/.openclaw/config.json`):
```json
{
  "hooks": {
    "enabled": true,
    "token": "your-secret-token",
    "path": "/hooks"
  }
}
```

#### WebSocket Protocol (for real-time streaming)

- Full bidirectional, protocol v3
- URL: `ws://127.0.0.1:18789`
- Device pairing, event subscriptions
- Request/response with message IDs

#### HTTP Tools Invoke (for single tool calls)

```
POST http://localhost:18789/tools/invoke
Authorization: Bearer <token>
Content-Type: application/json

{
  "tool": "web_search",
  "action": "json",
  "args": { "query": "weather in SF" },
  "sessionKey": "glass:default"
}
```

### OpenClaw Capabilities

OpenClaw has 56+ skills and 31+ extensions covering:

| Category | Examples |
|----------|----------|
| **Messaging** | WhatsApp, Telegram, Slack, Discord, iMessage, Signal, Teams, Matrix |
| **Web** | Search, fetch, full browser control |
| **Productivity** | Apple Notes, Reminders, Things, Obsidian, Notion, Trello |
| **Media** | Image gen (OpenAI), whisper transcription, TTS, camera |
| **Smart Home** | Via node.invoke + system.run on macOS/iOS nodes |
| **Developer** | GitHub, coding agent, tmux |
| **Music** | Spotify player |
| **Other** | 1Password, weather, food ordering, location-based services |

### Implementation Plan

#### Phase 1: Basic tool bridge
1. Add `tools` field to Gemini setup message with function declarations
2. Handle `toolCall` messages in `GeminiLiveService.handleMessage()`
3. Create `OpenClawBridge` class for HTTP calls to gateway
4. Send `toolResponse` back to Gemini with results
5. Start with 2-3 tools: `delegate_task`, `send_message`, `web_search`

#### Phase 2: Rich tool set
6. Add more specific tool declarations (reminders, notes, smart home, etc.)
7. Implement NON_BLOCKING behavior for long-running tasks
8. Add tool call status UI overlay (show what's happening)

#### Phase 3: Session continuity
9. Use Gemini session resumption for longer conversations
10. Use consistent `sessionKey` for OpenClaw to maintain multi-turn context
11. OpenClaw proactive callbacks (task completed, need input)

### Key Files

| File | Purpose |
|------|---------|
| `Gemini/GeminiConfig.swift` | API keys, model config, system instruction |
| `Gemini/GeminiLiveService.swift` | WebSocket client, message handling, tool call routing |
| `Gemini/AudioManager.swift` | Audio capture (Float32 tap, 4096 buffer, 100ms chunks) + playback |
| `Gemini/GeminiSessionViewModel.swift` | Session orchestration, transcript state |
| `Views/Components/GeminiOverlayView.swift` | Transcript UI, status bar, indicators |
| `Views/StreamView.swift` | Main streaming view |

### References

- [Gemini Live API - Tool Use](https://ai.google.dev/gemini-api/docs/live-tools)
- [Gemini Live API - WebSocket Reference](https://ai.google.dev/api/live)
- [Gemini Live API - Capabilities Guide](https://ai.google.dev/gemini-api/docs/live-guide)
- [Gemini Live - Function Calling Cookbook](https://deepwiki.com/google-gemini/cookbook/6.2-liveapi-tools-and-function-calling)
- [OpenClaw Webhook API](https://docs.openclaw.ai/automation/webhook)
- [OpenClaw Gateway Protocol](https://docs.openclaw.ai/gateway/protocol)
- [OpenClaw iOS Node](https://docs.openclaw.ai/platforms/ios)

## Troubleshooting

For issues related to the Meta Wearables Device Access Toolkit, please refer to the [developer documentation](https://wearables.developer.meta.com/docs/develop/) or visit our [discussions forum](https://github.com/facebook/meta-wearables-dat-ios/discussions)

## License

This source code is licensed under the license found in the LICENSE file in the root directory of this source tree.
