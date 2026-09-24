# Agent Architecture

This document describes the design of the autonomous multi-step planning and agent loop system in Jarvis.

## 🧭 Overview

The Jarvis Agent system enables the application to move beyond simple single-turn question-answering into highly autonomous, multi-step goal execution. When a task is classified as requiring multi-step execution (e.g., "Find the latest draft invoice, extract the total, search the web for currency conversions, update my local CSV, and send me a notification"), the **Agent Loop** is engaged.

The architecture relies on several core components cooperating over the central `EventBus`:
1. **TaskStateMachine**: Maintains the lifecycle of a task (Planning, Execution, Validation, Completion, Failure).
2. **Agent Planner (MLXPlanner or DirectComposer)**: Analyzes the goal, current workspace context, and available tools to output a linear or branched execution plan.
3. **PlanValidator**: Intercepts generated steps to verify safety rules, file system paths, and network targets.
4. **TaskWorker & TaskWorkerPool**: Concurrent workers executing individual tool calls asynchronously.
5. **PermissionGate**: Intercepts execution of high-risk tasks to ask the user for authorization via native overlay prompts.

---

## 🏗️ State Machine Flow

```
   [ User Request ]
          │
          ▼
   ┌──────────────┐
   │   Pending    │
   └──────┬───────┘
          │ (Intent Classification -> Agent Loop)
          ▼
   ┌──────────────┐
   │   Planning   │ ◄─────────────────────────┐
   └──────┬───────┘                           │
          │ (Plan generated)                  │ (Re-planning if step failed)
          ▼                                   │
   ┌──────────────┐                           │
   │  Executing   │ ──(Permission Denied)──►  │
   └──────┬───────┘                           │
          │ (Step execution success)          │
          ▼                                   │
   ┌──────────────┐                           │
   │  Validating  ├───────────────────────────┘
   └──────┬───────┘
          │ (Goal fully achieved)
          ▼
   ┌──────────────┐
   │  Completed   │
   └──────────────┘
```

---

## 🧩 Directory Breakdown

### `Sources/Jarvis/Agent/`

- **`AgentLoop.swift`**: The main orchestration class. It listens to the `EventBus` for agent-related goals, instantiates the State Machine, invokes the Planner, and feeds results back to the conversation engine.
- **`TaskStateMachine.swift`**: Tracks current tasks, execution history, and state transitions. It emits event notifications (e.g., `.taskStateChanged`) so the UI can draw active progress spinners, Gantt-like steps, or terminal output logs.
- **`MLXPlanner.swift`**: A localized planner utilizing a local MLX Llama model for offline plan generation, providing ultra-low-latency planning loops without API cost.
- **`DirectComposer.swift`**: A cloud-based provider-backed planner that formats available tool definitions into system instructions and constructs multi-step JSON execution schedules.
- **`PlanValidator.swift`**: Assesses safety constraints before steps run. If a tool execution contains highly dangerous patterns (like deleting directories, sweeping system folders, or reading secure keychain entries without permission), it marks the step as requiring explicit approval or flags it as an error.
- **`PermissionGate.swift`**: A thread-safe lock-and-release gate. It halts execution of high-risk actions, pops up a sleek native SwiftUI panel requesting permission, and resumes execution only upon explicit user approval.
- **`TaskWorker.swift` & `TaskWorkerPool.swift`**: Manages execution. Steps are processed sequentially or concurrently (depending on dependency graphs) using GCD `DispatchQueue` pools, capturing stdout, exit codes, or tool return structures.

---

## 🔒 Safety & Sandboxing

Our Agent Loop prioritizes local user safety:
* **Shell Sanbox**: The Shell Executor runs tasks within constraints. High-risk terminal activities undergo regular-expression-based and path-based restriction checks by `PlanValidator`.
* **Dynamic Interruption**: A user can click "STOP" in the UI menu bar or floating overlay at any millisecond to abruptly kill all sub-processes, reset the worker pool, and transition the task state directly to `.failed`.
* **Path Containment**: The `FileManagerJarvis` action engine restricts operations strictly to user-designated working directories (like `~/Downloads`, `~/Documents`, or the Jarvis workspace), preventing arbitrary system corruption.