# Architecture Guide: memory_context_engineering_agents-fassis.ipynb

This document explains the architecture implemented in the notebook and how memory engineering + context engineering are combined into a production-style agent harness.

## 1. High-Level System Architecture

```mermaid
flowchart LR
    U[User Query] --> A[call_agent]

    subgraph ContextAssembly[Programmatic Context Assembly]
      C1[Conversation Memory\nSQL table]
      C2[Knowledge Base\nOracleVS vector table]
      C3[Workflow Memory\nOracleVS vector table]
      C4[Entity Memory\nOracleVS vector table]
      C5[Summary Context\nIDs + descriptions]
    end

    A --> ContextAssembly
    ContextAssembly --> Ctx[Composed Context]
    Ctx --> Usage[Context Usage Check]
    Usage --> ToolsSel[Semantic Tool Retrieval\nfrom Toolbox Memory]

    ToolsSel --> LLM[Azure OpenAI Chat]
    LLM -->|tool_calls| Exec[Tool Executor]
    Exec --> LLM
    LLM -->|final answer| Persist[Persistence Layer]

    Persist --> W1[Write Assistant Message\nConversation Memory]
    Persist --> W2[Write Workflow Steps\nWorkflow Memory]
    Persist --> W3[Extract + Write Entities\nEntity Memory]
```

## 2. Request Lifecycle (Exact Function Order)

This is the exact runtime order in call_agent(query, thread_id).

```mermaid
flowchart TD
    S([Start: call_agent query, thread_id]) --> C0[Initialize empty steps list]
    C0 --> C1[Build context header with user question]
    C1 --> C2[read_conversational_memory thread_id]
    C2 --> C3[read_knowledge_base query]
    C3 --> C4[read_workflow query]
    C4 --> C5[read_entity query]
    C5 --> C6[read_summary_context query]
    C6 --> C7[calculate_context_usage]
    C7 --> C8[read_toolbox query k=5]
    C8 --> C9[read_toolbox summary-tool query k=5]
    C9 --> C10[Ensure expand_summary + summarize_conversation + summarize_and_store are present]
    C10 --> C11[write_conversational_memory user turn]
    C11 --> C12[write_entity from user text best effort]
    C12 --> L0[Enter LLM loop max_iterations]
```

## 3. Iteration Flow (Inside One Loop Turn)

This shows exactly what happens each iteration after the LLM response returns.

```mermaid
flowchart TD
    I0([Iteration n]) --> I1[call_openai_chat messages + dynamic_tools]
    I1 --> D1{message.tool_calls exists?}

    D1 -- No --> F1[final_answer = message.content]
    F1 --> F2[Exit loop]

    D1 -- Yes --> T1[Append assistant tool_call envelope to messages]
    T1 --> T2[For each tool_call]
    T2 --> T3[Parse arguments JSON]
    T3 --> D2{tool name == summarize_conversation?}
    D2 -- Yes --> T4[Force thread_id = active thread]
    D2 -- No --> T5[Keep arguments as provided]
    T4 --> T6[execute_tool name, args]
    T5 --> T6
    T6 --> D3{Tool execution error?}
    D3 -- Yes --> T7[result = Error string; append failed step]
    D3 -- No --> T8[result = tool output; append success step]
    T7 --> T9[Append tool result message]
    T8 --> T9
    T9 --> I0
```

## 4. Tool Branches That Change State

Not all tools just return text. These three branches modify persistent memory state.

```mermaid
flowchart LR
    A[Tool call selected by model] --> B{Which tool?}

    B -->|search_tavily| C1[Tavily API search]
    C1 --> C2[For each result build text + metadata]
    C2 --> C3[write_knowledge_base]
    C3 --> C4[(SEMANTIC_MEMORY updated)]

    B -->|summarize_conversation| D1[get_unsummarized_messages thread]
    D1 --> D2[summarise_context_window]
    D2 --> D3[write_summary summary_id]
    D3 --> D4[mark_as_summarized by summary_id]
    D4 --> D5[(SUMMARY_MEMORY + CONVERSATIONAL_MEMORY updated)]

    B -->|expand_summary| E1[read_summary_memory summary_id]
    E1 --> E2[Return stored summary text to model]
```

## 5. Persistence Timeline (When Each Table Is Written)

This timeline is useful to understand why the agent appears stateful across turns.

```mermaid
sequenceDiagram
    participant AG as call_agent
    participant MM as MemoryManager
    participant DB as Oracle Tables

    Note over AG,DB: Pre-loop writes
    AG->>MM: write_conversational_memory user
    MM->>DB: INSERT CONVERSATIONAL_MEMORY
    AG->>MM: write_entity from user text
    MM->>DB: INSERT ENTITY_MEMORY entries

    Note over AG,DB: In-loop optional writes
    AG->>MM: execute_tool search_tavily
    MM->>DB: INSERT SEMANTIC_MEMORY rows
    AG->>MM: execute_tool summarize_conversation
    MM->>DB: INSERT SUMMARY_MEMORY + UPDATE CONVERSATIONAL_MEMORY.summary_id

    Note over AG,DB: Post-loop writes
    AG->>MM: write_workflow if steps exist
    MM->>DB: INSERT WORKFLOW_MEMORY row
    AG->>MM: write_entity from final answer
    MM->>DB: INSERT ENTITY_MEMORY entries
    AG->>MM: write_conversational_memory assistant
    MM->>DB: INSERT CONVERSATIONAL_MEMORY
```

## 6. Context Compaction and Re-expansion

This is the practical mechanism that keeps context bounded without losing history.

```mermaid
flowchart TD
    R1[read_conversational_memory]
    R2[read_summary_context IDs + labels]
    R1 --> Ctx[Context sent to model]
    R2 --> Ctx

    Ctx --> D{Model needs older detail?}
    D -- No --> N[Continue reasoning]
    D -- Yes --> X[Call expand_summary summary_id]
    X --> Y[read_summary_memory]
    Y --> Z[Detailed summary returned to model]
    Z --> N

    N --> D2{Conversation too long?}
    D2 -- No --> End[Normal turn close]
    D2 -- Yes --> S1[Call summarize_conversation thread_id]
    S1 --> S2[get_unsummarized_messages]
    S2 --> S3[summarise_context_window]
    S3 --> S4[write_summary]
    S4 --> S5[mark_as_summarized]
    S5 --> End
```

## 7. Azure Request Path in This Notebook

This diagram maps the concrete aliasing approach used so downstream code stays unchanged.

```mermaid
flowchart TD
    E1[Read env: endpoint deployment api_version] --> E2[DefaultAzureCredential]
    E2 --> E3[get_bearer_token_provider scope cognitiveservices]
    E3 --> E4[AzureOpenAI client_azure]
    E4 --> E5[toolbox_azure = Toolbox memory_manager client_azure]

    E5 --> A1[Alias: toolbox = toolbox_azure]
    E4 --> A2[Alias: client = client_azure]
    A2 --> A3[Alias: call_openai_chat = call_openai_chat_azure]
    A3 --> A4[Alias: AGENT_SYSTEM_PROMPT = AGENT_SYSTEM_PROMPT_azure]

    A1 --> Run[call_agent uses aliases transparently]
    A4 --> Run
```

## 8. Why This Architecture Works

- Reliability: memory load/save is deterministic and not left to model discretion.
- Scalability: semantic tool retrieval avoids passing large tool catalogs every turn.
- Continuity: conversation + summaries + entities preserve long-horizon state.
- Efficiency: context compaction and JIT expansion reduce token pressure.
- Learning behavior: web/tool outputs are persisted back into long-term memory.

---

If you want, this can be followed by a second document with a component-by-component mapping table from notebook cell numbers to architecture blocks.
