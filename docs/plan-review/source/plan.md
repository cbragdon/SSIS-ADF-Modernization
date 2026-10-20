# Enterprise SSIS to Azure Data Factory (ADF) Migration Framework
## Core Strategic Architecture and Assessment Plan

This document establishes the strategic blueprint, model selection, execution matrix, and agentic orchestration framework required to safely migrate an enterprise repository of SSIS packages (`.dtsx`) into cloud-optimized data integration patterns.

---

## 1. Overall Migration Plan & Workflow

Migrating an enterprise data estate requires moving away from the anti-pattern of line-by-line programmatic code conversion. The strategy utilizes a **Deterministic-Generative Hybrid Pipeline** to isolate configuration states and programmatic logic, processing files safely within model limits.

```
                  [ Raw Enterprise .dtsx File ]
                                │
                                ▼
         ┌─────────────────────────────────────────────┐
         │ Step 1: PowerShell / Python Layout Stripper │
         └─────────────────────────────────────────────┘
                                │
                                ▼ 
            [ Streamlined Logic-Only XML (~40K Tokens) ]
                                │
             ┌──────────────────┴──────────────────┐
             ▼ (Fits safely within <273K limit)    ▼ (If isolated task >100K)
     ┌──────────────────────────────┐       ┌──────────────────────────────┐
     │  GitHub Copilot Pro Chat     │       │ Component Execution Isolation│
     │  (Whole Pipeline Structure)  │       │ (Isolate C# Scripts Solo)    │
     └──────────────────────────────┘       └──────────────────────────────┘
```

### Execution Strategy Breakdown:
1. **The Mandatory Layout Strip:** Before data is submitted to any evaluation engine, a local CLI script programmatically strips all graphical, coordinate, and font metadata (`<DTS:DesignTimeProperties>`) from the `.dtsx` schema. This eliminates visual layout bloat (which represents up to 90% of file size), reducing token volumes to protect context windows.
2. **Context-Aware Scoping:** The cleaned, logic-only XML is evaluated end-to-end to map global properties and connection topologies. 
3. **Component Isolation:** Heavy components, such as inline procedural code blocks, are programmatically extracted and evaluated as isolated execution targets.

---

## 2. Execution Architecture Matrix

This matrix establishes how the modernization runtime maps legacy on-premises workloads into specialized cloud execution targets based on complexity, dependencies, and integration models.

| Phase | Engine Component | Core Operational Responsibility | Architectural Rationale |
| :--- | :--- | :--- | :--- |
| **0. Discovery** | **Microsoft DMA (CLI Mode)** | Bulk scans local SSISDB/directories. Programmatically catalogs connection strings, data sources, and hard blockers. | Acts as the deterministic baseline filter. Identifies absolute environment and driver compatibility issues prior to AI invocation. |
| **1. Triage** | **Gemini 4 Argon** | Ingests streamlined `.dtsx` XML alongside DMA compliance metrics to compute semantic complexity scores. | The 1M output token capability allows long-horizon dependency tracking to determine the optimal target layout. |
| **2. Generation** | **Gemini 4 Argon / Claude Opus 5.5** | Emits production-grade ADF JSON definitions or orchestrates standalone cloud microservices. | Transforms imperative row-by-row procedural logic into cloud-native declarative architectures instead of basic ports. |

---

## 3. The Model Strategy (GitHub Copilot Integration)

Enterprise code refactoring requires matching specific sub-tasks to specialized models based on reasoning depth and structural format requirements.

* **Stage 1: Whole-Package Structural Triage (Gemini 4 Argon / Pro Series)**
  * *Objective:* Swallow unstripped or long-tail XML structures whole without truncation risk. Maps end-to-end data pipelines, operational connections, and variable dependency trees.
* **Stage 2: Script Task Re-engineering (Claude Opus 5.5)**
  * *Objective:* Acts as the high-tier reasoning engine. Safely extracts procedural C# or VB.NET data-flow buffers and refactors them into stateless, scalable Azure Functions or PySpark logic.
* **Stage 3: Logic Split & Expression Validation (GPT-6 Astra / Sol)**
  * *Objective:* Leverages deep chain-of-thought verification. Translates complex legacy SSIS property expressions and mathematical conditional splits cleanly into valid ADF dynamic expressions.

---

## 4. Recommended CLI Workflow for the Assessment Phase

The assessment can be controlled directly from the developer terminal using the `gh` platform wrapper and environment configuration toggles.

### Step 1: View Available Compute Engines
Verify that your active GitHub platform context has the necessary frontier inference models exposed:
```bash
gh models list
```

### Step 2: Set Target Session Context
Initialize your Copilot CLI workspace pinned directly to the target reasoning model for the translation session:
```bash
copilot --model claude-opus-5.5
```

### Step 3: Execute Single-Shot Pipeline Assessment
Pipe an isolated, unstripped legacy code fragment directly into the specific target engine via terminal execution to capture structural recommendations:
```bash
gh models run openai/gpt-6-astra "Analyze this SSIS Script Task and write the equivalent Azure Function C# code: $(cat script_task.cs)"
```

### Step 4: Configure Bring-Your-Own-Key (BYOK) Gateway
For large-scale processing loops leveraging external endpoints (such as Vertex or specialized Gemini instances), export the connectivity profiles into your command-line workspace:
```bash
export COPILOT_PROVIDER_TYPE="openai"
export COPILOT_PROVIDER_BASE_URL="https://your-custom-gateway-endpoint/v1"
export COPILOT_PROVIDER_API_KEY="your-secure-api-token"
export COPILOT_MODEL="gemini-4-argon"
copilot
```

---

## 5. Agentic Workflow Architecture

To run migrations at scale, the operational engine shifts away from standalone chat prompting and moves into a multi-agent orchestration architecture.

```
                     [ Core SSIS Ingestion Engine ]
                                   │
                                   ▼
                   ┌───────────────────────────────┐
                   │   Agent 1: The Triage Agent   │ ──► Parses XML & DMA Reports
                   └───────────────┬───────────────┘
                                   │
         ┌─────────────────────────┼─────────────────────────┐
         ▼                         ▼                         ▼
┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐
│    Agent 2A     │       │    Agent 2B     │       │    Agent 2C     │
│ The Structural  │       │   The Script    │       │  The Expression │
│    Architect    │       │   Modernizer    │       │    Translator   │
│ (Generates ADF  │       │ (C# ──► Azure   │       │ (Maps formulas  │
│  Control Flow)  │       │    Functions)   │       │    to Cloud)    │
└────────┬────────┘       └────────┬────────┘       └────────┬────────┘
         │                         │                         │
         └─────────────────────────┼─────────────────────────┘
                                   │
                                   ▼
                   ┌───────────────────────────────┐
                   │  Agent 3: The Compiler Agent  │ ──► Assembles raw JSON & code
                   └───────────────┬───────────────┘
                                   │
                                   ▼
                   ┌───────────────────────────────┐
                   │  Agent 4: The Validator Agent │ ──► Runs schema check & flags bugs
                   └───────────────┬───────────────┘
                                   │
                                   ▼
                       [ Human Architect Review ]
```

### Agent Roles and Responsibilities:

* **Agent 1: The Triage Agent (The Discovery Engine)**
  Ingests Microsoft DMA execution logs alongside stripped `.dtsx` logic trees. Maps out package topologies, connection schemas, and computes complexity metrics to route components to optimal cloud infrastructure targets.
* **Agent 2A: The Structural Architect**
  Maps legacy control flow blocks straight to active Azure Data Factory pipeline activities. Translates sequence configurations, execution loops, and basic connection properties.
* **Agent 2B: The Script Modernizer**
  Isolates embedded custom code fragments. Refactors imperative local file and row-by-row memory manipulation loops into detached cloud constructs like Azure Functions or modern distributed PySpark blocks.
* **Agent 2C: The Expression Translator**
  Scans legacy packages for inline properties, runtime variables, and internal system formulas, converting them to native cloud parameters.
* **Agent 3: The Compiler Agent (The Assembler)**
  Stitches the discrete JSON structures and external source code assets generated by the parallel worker agents back together into unified Azure Resource Manager (ARM) package definitions.
* **Agent 4: The Validator Agent (The Quality Gate)**
  Automatically parses and tests compiled deployment outputs against live, production-grade Azure Data Factory JSON schemas. Evaluates structural dependencies and flags configuration errors before final engineering review.