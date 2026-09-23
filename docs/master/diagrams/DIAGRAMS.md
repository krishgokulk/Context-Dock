# DoraX — diagram gallery

One diagram per master doc, plus a whole-app overview. Each renders on GitHub. Sources are the
`.mmd` files beside this page. Companion to the [master docs](../README.md).

> Diagrams are drawn from the code-verified surface docs (`../01`…`../10`). Where a doc marks a
> `[gap]` or `[?]`, the diagram shows it too (e.g. the eval gap in #10).

---

## 00 · Whole-app overview

```mermaid
flowchart TB
    U([User on macOS]) --> SURF
    subgraph SURF[Six product surfaces · one job each]
      direction LR
      S1[01 Global Context<br/>search & launch]
      S2[02 Context Dock<br/>frontmost commands]
      S3[03 App-Scoped Chat<br/>this app]
      S4[04 General Chat<br/>whole Mac]
      S5[05 Selection + Clipboard<br/>act on selection]
      S6[06 Media Dock<br/>media control]
    end
    S3 --> ENG
    S4 --> ENG
    S2 -.menus/actions.-> EXEC
    S1 -.launch/execute.-> EXEC
    S5 -.actions.-> EXEC
    subgraph ENG[08 AI Engine · shared]
      direction TB
      E1[router → grounding → classify] --> E2[3 loops: reactive · plan-DAG · tool-less] --> E3[tools · budget · verify · approval]
    end
    ENG --> EXEC[Capability layer<br/>GeneralAIActionExecutor · MenuExecution]
    EXT[07 Extensions L1/L2/L3<br/>+ App Adapters] --> ENG
    EXEC --> APPS([Other macOS apps<br/>menus · MCP · Shortcuts · CLI])
    ENG --> MEM
    SURF --> MEM
    subgraph MEM[09 Second Brain · memory]
      M1[(markdown vault)]
      M2[dashboard + knowledge graph]
    end
    XC[[10 Cross-cutting:<br/>evaluation · safety · performance · security]] -.governs.- ENG
    XC -.governs.- SURF
```

---

## 01 · Global Context

```mermaid
flowchart TD
    Q([User types a query]) --> IDX[Search the cache-first index<br/>no AX / menu scan while typing]
    IDX --> SRC{Match across sources}
    SRC --> A1[Installed + running apps]
    SRC --> A2[App menu commands]
    SRC --> A3[Global / universal commands]
    SRC --> A4[Extensions L1]
    SRC --> A5[CLI / TUI tools]
    SRC --> A6[Files / folders / docs]
    SRC --> A7[Apple-app content]
    SRC --> A8[Web search]
    A1 & A2 & A3 & A4 & A5 & A6 & A7 & A8 --> RANK[Rank: n-gram + learned-usage boost]
    RANK --> ROW[Top-match icon row]
    RANK --> LIST[Results list]
    ROW --> SEL{User picks one}
    LIST --> SEL
    SEL -->|app| LAUNCH[Launch / expand]
    SEL -->|menu command| EXE[MenuExecutionCoordinator]
    SEL -->|attach folder/mail| BRIDGE[Attach to a chat scope → 03/04]
```

---

## 02 · Context Dock (frontmost command layer)

```mermaid
flowchart TD
    OPEN([Dock opens]) --> FM[Detect frontmost app<br/>previousFrontmostApp]
    FM --> SRC{Gather this app's commands}
    SRC --> C1[Verified menu commands]
    SRC --> C2[App adapter actions]
    SRC --> C3[App extensions]
    C1 & C2 & C3 --> PILL[ContextDockPillCoordinator<br/>cached + preview pills · debounce]
    PILL --> SHEET[Stable result sheet]
    TYPE([User types]) --> FILTER[Filter existing rows inline] --> SHEET
    SHEET --> PICK{User selects a pill} --> EXE[MenuExecutionCoordinator]
    AX[AX pipeline] -.keeps scope current.-> FM
```

---

## 03 · App-Scoped Chat

```mermaid
flowchart TD
    U([User asks in an app-scoped chat]) --> G[Build grounding<br/>appIdentityBlock]
    G --> B[prepareTurnBudget]
    B --> CL{Multi-step? or 2+ apps}
    CL -- Yes --> PLAN[Plan a DAG · ChatPlanRunner] --> PRUN[Run steps · per-step auth] --> V
    CL -- No / native tools --> M[Send to model]
    CL -. no function-calling .-> TL[Tool-less prose loop] --> V
    M --> D{Model wants a tool?}
    D -- No --> V
    D -- Yes --> RES[reserveToolCall] --> ROUTE[Tool-choice order] --> ACC{Access + approval}
    ACC -- denied --> M
    ACC -- approved/allowed --> EXE[Execute route] --> FEED[Feed result back] --> M
    V{Verify answer}
    V -- unproven --> M
    V -- ok --> OUT([Answer + receipts])
```

---

## 04 · General AI Chat

```mermaid
flowchart TD
    Q([User asks · scope = .general]) --> FRONT
    subgraph FRONT[General-Chat front-end]
      F1[Scope resolution] --> F2[Cross-app clarifier] --> F3[Action resolution] --> F4[Capability hub] --> F5[Local evidence]
    end
    FRONT --> GATE{App needed but not granted?}
    GATE -->|yes| ENABLE[Enable app for this chat · re-ask] --> FRONT
    GATE -->|no| ENG[Shared engine → 08]
    ENG --> GAP{Capability gap?}
    GAP -->|yes| SAY[Say what IS possible]
    GAP -->|no| ANS([Answer + receipts])
```

---

## 05 · Selection + Clipboard

```mermaid
flowchart TD
    subgraph SEL[Selection Shortcut Sheet]
      H([Long-press Command]) --> READ[Read selection ONCE] --> IN[Inputs: text·file·image·url·clipboard·app]
      IN --> MATCH[Match triggers] --> ACT{Action sources}
      ACT --> B1[Built-in ext] & B2[User ext] & B3[Menu/adapters] & B4[Shortcuts] & B5[AI actions]
      B1 & B2 & B3 & B4 & B5 --> RUN[Run action]
    end
    subgraph CLIP[Clipboard · ambient]
      COPY([Any copy]) --> PILL[Corner pill · independent of dock] --> CARD[Card of recent clips] --> USE[Paste / feed to action]
    end
    CARD -.clipboard is also an input.-> IN
```

---

## 06 · Media Dock

```mermaid
flowchart TD
    SYS[(macOS MediaRemote · private)] <-->|dlopen| BRIDGE[MediaRemoteBridge<br/>play·pause·next·prev·seek]
    BRIDGE --> OBS[Observer / InfoProvider] --> ENGINE[MediaDockEngine<br/>title·artist·album·isPlaying]
    ENGINE --> UI[Dock row + controls] --> CMD{Tap control} --> BRIDGE
    ENGINE -.capability.-> MCP[AppleMusicMCPCapabilities] -.-> ENG08[AI Engine · 08]
```

---

## 07 · Extensions (L1/L2/L3)

```mermaid
flowchart TD
    subgraph L1[L1 · keyword quick actions]
      L1a[Built-in ext] 
      L1b[User global ext · userext://]
    end
    subgraph L2[L2 · context actions + tools]
      L2a[Custom terminal tools<br/>extension.json + script]
      L2b[CLI tools]
      L2c[The AI assistant]
    end
    subgraph L3[L3 · web]
      L3a[Safari Web Extension]
      L3b[AX web readers]
    end
    L1 --> SURF1[Global Context · Selection Sheet]
    L2a & L2b --> REG[CapabilityRegistry]
    ADAPT[App Adapters] --> REG
    REG --> ENG[AI Engine · 08]
    L3 --> ENG
```

---

## 08 · AI Engine

```mermaid
flowchart TD
    REQ([Request]) --> ROUTER[AIProviderRouter] --> GROUND[Grounding] --> CLASS{Classify}
    CLASS -->|multi-step| PLAN[Plan DAG · ChatPlanRunner]
    CLASS -->|native tools| LOOP[Reactive tool loop]
    CLASS -->|no function-calling| TL[Tool-less prose loop]
    PLAN & LOOP & TL --> TOOLS[Tool registry<br/>run_capability · run_menu_command · run_mcp_tool<br/>run_command · send_keys · spawn_worker · verify]
    TOOLS --> BUDGET[Budget + durable receipts] --> AUTH{Authority · access · risk}
    AUTH -->|critical| DENY[Hard-denied]
    AUTH -->|needs approval| APPROVE[ApprovalCenter] -->|approved| RUN
    AUTH -->|allowed| RUN[Execute]
    RUN --> VERIFY{Verify}
    VERIFY -->|unproven| LOOP
    VERIFY -->|ok| ANS([Answer]) --> LEDGER[(Token ledger · prompt cache)]
```

---

## 09 · Second Brain (memory)

```mermaid
flowchart TD
    subgraph PERCEIVE[Live perception]
      P2[Quick Note] 
      P3[chat conversations]
      P4[task-run receipts]
    end
    P2 --> W1[QuickNoteMemoryMirror]
    P3 --> W2[ConversationDistiller · no model]
    P4 --> W3[DailyBrief · BrainMaintenance]
    W1 & W2 & W3 --> VAULT[(Markdown vault · MarkdownMemoryStore)]
    VAULT --> RET[Retrieval · ranked sections] --> TURN[Injected into a turn → 08]
    VAULT --> DASH[DashboardMetrics · read-back] --> GRAPH[KnowledgeGraphView · real scope links]
```

---

## 10 · Cross-cutting (eval · safety · performance · security)

```mermaid
flowchart TD
    REQ([Request]) --> PERF[PERFORMANCE<br/>sync input · debounce · cache-first · no AX while typing]
    PERF --> SAFE[SAFETY<br/>critical hard-denied · AppAccessLevel · ScopeGuard · ApprovalCenter]
    SAFE --> EXEC[Execute]
    EXEC --> EVAL
    subgraph EVAL[EVALUATION]
      EV1[Runtime verifiers]
      EV2[~135 offline eval tests]
      EV3[GAP: no aggregate pass-rate · no memory eval]
    end
    EVAL --> ANS([Answer])
    SECURITY[[SECURITY spans all: sandbox · dlopen · keys-not-prompts · elevated tools · privacy]] -.- PERF
    SECURITY -.- SAFE
    SECURITY -.- EXEC
```
