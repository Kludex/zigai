# Error reference

ZigAI returns named errors for framework decisions and preserves allocator,
runtime, transport implementation, and application callback errors alongside
them. Public operations therefore use inferred error unions: handle the named
cases relevant to the application, then propagate the remainder.

## Agent errors

### Context and usage

| Error | Meaning |
| --- | --- |
| `ContextPromptTooLarge` | Provider-facing prompt text exceeds its byte budget. |
| `ContextToolsTooLarge` | Tool definitions or tool traffic exceed their byte budget. |
| `ContextSchemaTooLarge` | Tool or output schemas exceed their byte budget. |
| `ContextMediaTooLarge` | Rich-media sources exceed their raw byte budget. |
| `ContextTokenLimitExceeded` | Estimated input exceeds total capacity after output reservation. |
| `ContextSizeOverflow` | Aggregate context size cannot be represented as `u64`. |
| `InputTokenLimitExceeded` | Provider-reported cumulative input usage exceeded the run limit. |
| `OutputTokenLimitExceeded` | Provider-reported cumulative output usage exceeded the run limit. |
| `TotalTokenLimitExceeded` | Provider-reported combined usage exceeded the run limit. |
| `CostLimitExceeded` | Available provider-reported or estimated cost exceeded the nano-USD run limit. |
| `UsageOverflow` | A usage counter, duration, or exact cost exceeded its integer representation. |
| `MaxModelRequestsExceeded` | The run exhausted its model-request budget. |
| `MaxToolCallsExceeded` | The run exhausted its local tool-call budget. |

### Model capabilities and output

| Error | Meaning |
| --- | --- |
| `ModelDoesNotSupportAudio` | Audio was supplied to a model profile without audio support. |
| `ModelDoesNotSupportBinaryContent` | Generic binary content is unsupported. |
| `ModelDoesNotSupportDocuments` | Documents are unsupported. |
| `ModelDoesNotSupportImages` | Images are unsupported. |
| `ModelDoesNotSupportSystemMessages` | System prompts or instructions are unsupported. |
| `ModelDoesNotSupportThinking` | Thinking content cannot be preserved. |
| `ModelDoesNotSupportTools` | Local tools are unsupported. |
| `ModelDoesNotSupportVideo` | Video was supplied to a model profile without video support. |
| `ModelDoesNotSupportWebFetch` | Native web fetch is unsupported. |
| `ModelDoesNotSupportWebSearch` | Native web search is unsupported. |
| `ModelDoesNotSupportXSearch` | Native X search is unsupported. |
| `ModelDoesNotSupportCodeExecution` | Provider-managed code execution is unsupported. |
| `ModelDoesNotSupportFileSearch` | Provider-managed file search is unsupported. |
| `ModelDoesNotSupportRemoteMcp` | Provider-managed remote MCP is unsupported. |
| `ModelDoesNotSupportJsonObjectOutput` | JSON-object output is unsupported. |
| `ModelDoesNotSupportJsonSchemaOutput` | JSON Schema output is unsupported. |
| `ModelDoesNotSupportMaxTokens` | The model rejects `max_tokens`. |
| `ModelDoesNotSupportReasoningEffort` | The requested reasoning effort is unsupported. |
| `ModelDoesNotSupportSeed` | The model rejects deterministic seeds. |
| `ModelDoesNotSupportStopSequences` | The model rejects stop sequences. |
| `ModelDoesNotSupportStreaming` | The selected model cannot stream. |
| `ModelDoesNotSupportTemperature` | The model rejects temperature. |
| `ModelDoesNotSupportTopP` / `ModelDoesNotSupportTopK` | The requested sampling control is unsupported. |
| `ModelDoesNotSupportPresencePenalty` / `ModelDoesNotSupportFrequencyPenalty` | The requested penalty is unsupported. |
| `ModelDoesNotSupportLogprobs` | The model cannot return requested log probabilities. |
| `ModelDoesNotSupportToolChoice` | The model cannot encode the requested tool-choice policy. |
| `ModelDoesNotSupportParallelToolCallSetting` | The provider cannot encode an explicit parallel-tool policy. |
| `ModelDoesNotSupportThinkingBudget` | The model cannot accept a thinking token budget. |
| `ModelDoesNotSupportServiceTier` | The requested service tier is absent from the profile. |
| `ModelDoesNotSupportTruncation` | The model cannot encode truncation policy. |
| `ModelDoesNotSupportRequestHeaders` | The model does not expose request-scoped headers. |
| `ModelDoesNotSupportExtraBody` | The provider-extension tag does not match the model profile. |
| `InvalidModelSettings` | A portable value, tool selector, or request header is malformed. |
| `ContentFiltered` | Provider filtering ended generation. |
| `EmptyModelResponse` | A successful response had no usable parts. |
| `IncompleteToolCall` | Generation ended inside a tool call. |
| `ModelOutputTruncated` | Length termination prevented a complete result. |
| `InvalidTypedOutput` | Validated structured output could not decode as the requested Zig type. |
| `InvalidStructuredOutput` | Structured output could not decode for the final stream snapshot. |
| `InvalidOutputSpec` | An output name, schema, alternative list, or prompt template is malformed. |
| `ModelDoesNotSupportPromptedOutput` | Prompted output was selected for a model without instruction support. |
| `OutputToolRequired` | Tool-output mode received no output-tool call before its retry budget ended. |
| `OutputRetriesExceeded` | An output function or validator requested another attempt after its retry budget ended. |
| `ProviderFileProviderMismatch` | A provider-managed file belongs to another provider. |
| `PendingMessageQueueAlreadyUsed` | A one-run pending-message queue was attached again. |
| `PendingMessageQueueClosed` | A message was submitted after the queue stopped accepting input. |

### Tools and deferred runs

| Error | Meaning |
| --- | --- |
| `DuplicateToolName` | Two local tools have the same provider-visible name. |
| `DuplicateBuiltinTool` | A provider-managed tool identity was registered twice. |
| `DuplicateCapabilityId` | Two composed capability scopes declare the same stable ID. |
| `InvalidCapability` | A capability ID, metadata list, dependency, conflict, limit, or active-state declaration is invalid. |
| `MissingCapabilityDependency` | A dependency ID is absent from the composed capability registry. |
| `CapabilityDependencyCycle` | Capability dependencies contain a cycle. |
| `CapabilityConflict` | Initial capability composition would activate two conflicting bundles. |
| `UnknownTool` | The model requested a tool unavailable in the current step. |
| `ParallelToolCallsNotSupported` | The model emitted parallel calls while policy disabled them. |
| `ParallelToolCallsRequireIo` | Parallel execution requires an `Io` runtime. |
| `ToolConcurrencyUnavailable` | The runtime cannot schedule the controlled tool tasks. |
| `ToolIsolationRequiresIo` | A timeout or concurrency control requires `Io`. |
| `ToolQueueOverflow` | Too many tool calls are waiting for a slot. |
| `ToolResultTooLarge` | Encoded tool output exceeds its byte limit. |
| `ToolFollowUpOverflow` | Tool follow-up count or aggregate bytes exceed policy. |
| `ToolTimedOut` | A local tool exceeded its timeout. |
| `ToolCallRequiresDeferredRun` | A normal run encountered approval or external execution. |
| `MissingDeferredToolDecision` | A paused call has no resume decision. |
| `UnexpectedDeferredToolDecision` | A decision does not match a paused call. |
| `DeferredToolRequiresResult` | External execution resumed without a result. |
| `InvalidDeferredState` | Paused state or resume JSON is malformed or incompatible. |
| `InvalidContentRole` | A follow-up part is invalid for a request message. |
| `InvalidToolFollowUpMessage` | A follow-up violates provider message invariants. |
| `DurableOperationFailed` | A durable worker returned a persisted failure. |
| `DurableOperationSuspended` | A worker suspended an operation outside a resume-aware path. |
| `MissingDurableHandler` | A required model, timer, tool, or resume worker is not registered. |
| `MissingDurableToolsetOrigins` | A dynamic toolset did not declare its possible durable tool families. |

On-demand load failures such as `UnknownCapability`,
`CapabilityAlreadyAvailable`, `InvalidCapabilityArguments`, and a dynamic
`CapabilityConflict` are ordinary recoverable tool failures. They are returned
to the model from `load_capability`; they do not escape as an agent setup error
or partially activate a bundle.

### Runtime control

| Error | Meaning |
| --- | --- |
| `Cancelled` | The run's cancellation token was signalled. |
| `RunTimedOut` | The invocation deadline elapsed. |
| `RunControlRequiresIo` | A deadline was configured without `Io`. |
| `RunControlConcurrencyUnavailable` | The runtime cannot schedule an operation and its watchers. |
| `RetryBackoffRequiresIo` | Retry sleep was configured without `Io`. |
| `RetryIdempotencyRequiresIo` | Idempotent retry keys need an `Io` entropy source. |

### Security policy

| Error | Meaning |
| --- | --- |
| `InvalidUrl` | An outbound or provider-fetched value is not a valid absolute URL. |
| `UrlMissingHost` | The URL has no network host. |
| `UrlSchemeNotAllowed` | The URL is not HTTPS and HTTP was not enabled. |
| `UrlCredentialsForbidden` | The URL embeds a username or password. |
| `LocalNetworkUrlForbidden` | The URL uses a local name or non-public literal IP. |
| `UrlHostNotAllowed` | The URL host is absent from an explicit allowlist. |
| `UrlOriginNotAllowed` | A provider-directed URL does not match the configured API origin. |

### MCP authorization

| Error | Meaning |
| --- | --- |
| `InvalidAuthorizationIssuer` | A token, response, or metadata document is bound to a different authorization-server issuer. |
| `MissingAuthorizationIssuer` | RFC 9207 support was advertised but the authorization response omitted `iss`. |
| `InvalidAuthorizationServerMetadata` | Discovered OAuth/OIDC metadata is missing required fields or contains an ineligible endpoint. |
| `InvalidProtectedResourceMetadata` | RFC 9728 metadata is malformed, mismatched, duplicated, or lacks Bearer-header support. |
| `InvalidResourceUri` | The configured RFC 8707 resource is not an eligible canonical endpoint URI. |
| `PkceUnsupported` | Authorization-server metadata does not advertise `S256`. |
| `InvalidBearerChallenge` | A `WWW-Authenticate` Bearer challenge is malformed or ambiguous. |
| `InvalidBearerToken` | A token is empty, unsafe for an HTTP header, malformed, or conflicts with a configured token provider. |
| `InvalidOrigin` | A present browser Origin is malformed, duplicated, or outside the exact allowlist. |
| `InvalidRequestHost` | A required Host is absent, malformed, duplicated, or does not match deployment policy. |
| `InsecureHttpTransport` | A protected server request arrived over cleartext without an explicit development opt-in. |

## Provider errors

All adapters use the stable `ProviderRequestError` categories.

| Error | Meaning | Retried by default |
| --- | --- | --- |
| `ProviderConnectionError` | A recognized DNS, connect, or connection-lifetime failure. | Yes |
| `ProviderResponseDecodeError` | A success payload cannot be decoded. | Yes |
| `ProviderRateLimited` | HTTP 429. | Yes |
| `ProviderServerError` | HTTP 5xx. | Yes |
| `ProviderRequestFailed` | Another non-success status. | No |

Adapters additionally expose `InvalidProviderResponse` for direct decoder
calls and `InvalidRequestEncoding` for unrepresentable input. OpenAI adds
`UnsupportedBuiltinTool` and `UnsupportedContentType`. Anthropic adds
`UnsupportedContentType` and `UnsupportedOutputMode`. Google adds
`UnsupportedContentType`.

`ProviderErrorObserver` is infallible and synchronous. Its values are borrowed.
Raw bodies are empty unless `ProviderErrorPolicy.capture_body` is enabled, and
even then they cannot exceed `max_body_bytes`. Configured API keys are always
suppressed; `sensitive_data_redacted` reports when this changed visible detail.

Provider construction and optional operations use these boundary errors:

| Namespace | Error | Meaning |
| --- | --- | --- |
| `provider` | `InvalidProviderPolicy` | Identity, API root, timeout, or URL policy is invalid. |
| `provider` | `UnsupportedProviderOperation` | The provider does not implement the requested discovery or file operation. |
| `provider` | `InvalidProviderFileInput` | Upload metadata is empty, oversized, unsafe for multipart framing, or unsupported by the provider. |
| `provider` | `ProviderFileTooLarge` | Upload bytes exceed the configured provider file limit. |
| `provider` | `InvalidProviderFileOwner` | A file handle or returned descriptor belongs to another provider. |
| `provider` | `InvalidProviderFileReference` | A file handle is empty, or an operation returned metadata for another file ID. |
| `providers.http` | `InvalidProviderCredential` | A credential is empty or unsafe for an HTTP header. |
| `providers.http` | `InvalidProviderEndpoint` | The API root or adapter endpoint is ambiguous or not relative. |
| `providers.http` | `InvalidProviderHeader` | A configured or adapter header is malformed. |
| `providers.http` | `ProviderHeaderConflict` | Two layers claim the same case-insensitive header name. |

## Transport and data errors

| Namespace | Error | Meaning |
| --- | --- | --- |
| `transport` | `ResponseTooLarge` | A decompressed buffered body exceeded policy. |
| `transport` | `StreamLineTooLarge` | A decompressed stream line exceeded policy. |
| `transport` | `RequestCancelled` | Cancellation interrupted transport work. |
| `transport` | `RequestTimedOut` | The transport deadline elapsed. |
| `transport` | `StreamingNotSupported` | The transport has no line-streaming implementation. |
| `transport` | `UnsupportedCompressionMethod` | The response encoding cannot be decompressed. |
| `transport` | `RedirectRejected` | A 3xx response was rejected without following its target. |
| `json` | `DocumentTooLarge` | Encoded JSON exceeds its boundary limit. |
| `json` | `ValueTooLarge` | One decoded string or encoded number is too large. |
| `json` | `NestingTooDeep` | JSON nesting exceeds policy. |
| `json` | `CollectionTooLarge` | One object or array has too many entries. |
| `json` | `InvalidJson` | Input is not one complete JSON document. |
| `json_schema` | `InvalidJsonOutput` | Structured output is not valid JSON. |
| `json_schema` | `InvalidJsonSchema` | The configured schema is invalid. |
| `json_schema` | `UnsupportedJsonSchema` | The schema uses vocabulary outside ZigAI's documented fail-closed subset. |
| `json_schema` | `OutputSchemaValidationFailed` | Output does not satisfy the schema. |
| `history` | `InvalidHistory` | History JSON or message sequence is invalid. |
| `history` | `UnsupportedVersion` | The history version is unsupported. |
| `codecs.pydantic_ai` | `InvalidMessages` | Valid JSON does not have the PydanticAI stable-v2 message shape. |
| `messages.ProviderDetails.fromValue` | `InvalidProviderDetails` | Provider details are not a JSON object. |
| `context_budget` | `ContextSizeOverflow` | Byte or estimate arithmetic overflowed. |
| `evals` | `MissingExpectedOutput` | An evaluator requires an absent expected value. |
| `evals` | `InvalidModelGrade` | A model grader returned an invalid grade. |
| `evals` | `InvalidExecutionOptions` | Repetitions, concurrency, or task/evaluator attempt limits are zero, or run-count arithmetic overflowed. |
| `evals` | `ConcurrentExecutionRequiresIo` | More than one eval run was requested concurrently without a `std.Io` runtime. |
| `evals` | `ConcurrentExecutionUnavailable` | The supplied runtime could not admit eval work. |
| `evals` | `InvalidReportAnalysis` | A report evaluator returned a non-finite scalar value. |
| `evals` | `TraceEvaluationRequiresTelemetry` | Trace evaluators were configured on a dataset whose agent has no OpenTelemetry configuration. |
| `eval_io` | `InvalidDataset` | Dataset shape, names, metadata, or uniqueness constraints are invalid. |
| `eval_io` | `UnsupportedDatasetVersion` | The dataset document version is unsupported. |
| `eval_io` | `UnsupportedCaseOptions` | A case contains non-portable run options that cannot be serialized safely. |
| `eval_io` | `UnknownEvaluator` | A serialized evaluator name is absent from its registry category. |
| `eval_io` | `AmbiguousEvaluator` | A registry contains more than one evaluator with the requested name. |
| `eval_io` | `InvalidReport` | Report structure, identity, usage, score, span, or analysis data is invalid. |
| `eval_io` | `UnsupportedReportVersion` | The report document version is unsupported. |
| `eval_compare` | `InvalidLabel` | A baseline or candidate label is empty. |
| `eval_compare` | `InvalidReport` | A report contains invalid identities, names, or non-finite scores/analysis values. |
| `eval_compare` | `DuplicateCaseIdentity` | A report repeats one `(case_index, repetition)` identity. |
| `eval_compare` | `DuplicateEvaluator` | A case or report repeats one evaluator name. |
| `eval_compare` | `CaseIdentityMismatch` | Baseline and candidate use different names for the same stable case/run identity. |

### Agent specification errors

| Error | Meaning |
| --- | --- |
| `InvalidAgentSpec` | JSON/YAML shape, identifier, value, duplicate, or bound is invalid. |
| `UnsupportedAgentSpecVersion` | The document version is not supported. |
| `InvalidEnvironmentInterpolation` | A placeholder is malformed. |
| `EnvironmentVariableNotAllowed` | A secret reference or placeholder is outside its explicit allowlist. |
| `MissingEnvironmentVariable` | An allowed environment value is unavailable. |
| `EmptySecret` | An allowed secret variable exists but is empty. |
| `UnknownProvider` / `UnknownModel` | The application resolver does not recognize the selection. |
| `InvalidProviderConfiguration` | The resolver rejects the expanded endpoint or provider fields. |
| `UnknownCapability` | No implementation exists for a declared capability or dependency. |
| `InvalidCapabilityImplementation` | A catalog entry is anonymous or returns a different ID. |
| `InvalidCapabilityComposition` | The resolved registry has a structural, dependency, cycle, or conflict diagnostic. |

`ProviderResolver.buildFn` is an application extension point. Its allocation,
client-construction, and application errors propagate unchanged. Dry-run
validation never invokes it.

## Durable execution errors

| Error | Meaning |
| --- | --- |
| `InputDigestMismatch` | A persisted operation key was reused with changed input. |
| `InvalidInvocation` | A run, step, or handler identity is malformed. |
| `InvalidPayload` | An operation input or output is not bounded valid JSON. |
| `InvalidRecord` | A persisted record is malformed or ambiguous. |
| `MissingHandler` | No worker registration ID was configured for the operation kind. |
| `OperationFailed` | A runtime returned a persisted failure outcome. |
| `OperationSuspended` | A runtime returned a suspension outside a resume-aware API. |
| `RuntimeRecordMismatch` | A runtime returned a record for a different invocation. |
| `UnsupportedRecordVersion` | A durable record uses an unsupported format version. |
| `checkpoint.Error.InvalidCheckpoint` | A checkpoint identity, cursor, revision, state document, or snapshot is malformed. |
| `checkpoint.Error.CheckpointTooLarge` | Checkpoint state or its file snapshot exceeds its configured bound. |
| `checkpoint.Error.CheckpointConflict` | Equal revisions differ, the kind changed, or a stream cursor moved backward. |
| `checkpoint.Error.StaleCheckpoint` | A save attempted to replace a newer revision. |
| `checkpoint.Error.UnsupportedCheckpointVersion` | A checkpoint snapshot uses an unsupported format version. |
| `durable_adapters.temporal.Error.InvalidConfiguration` | Temporal endpoint, queue, timeout, retry, limit, or registration settings are invalid. |
| `durable_adapters.temporal.Error.MissingRegistration` | An invocation has no matching Temporal worker registration. |
| `durable_adapters.temporal.Error.InputTooLarge` | The persisted operation input exceeds the adapter limit. |
| `durable_adapters.temporal.Error.RequestTooLarge` | The complete sidecar request exceeds the durable payload limit. |
| `durable_adapters.temporal.Error.ResponseTooLarge` | The sidecar returned a record above the durable record limit. |
| `durable_adapters.temporal.Error.GatewayRejected` | The sidecar returned a non-success HTTP status. |

## Graph errors

| Error | Meaning |
| --- | --- |
| `EmptyNodeName` / `NodeNameTooLong` | A step or decision name is empty or exceeds the definition limit. |
| `DuplicateNodeName` | Two nodes use the same graph-local name. |
| `InvalidNode` | An entry or edge references an ID outside its definition. |
| `InvalidEdgeKind` | A non-decision received a named route, or a decision received an unconditional route. |
| `EmptyBranchName` / `BranchNameTooLong` | A decision/fan-out branch is empty or exceeds the definition limit. |
| `DuplicateBranchName` | A decision or fan-out registers the same branch name twice. |
| `MissingParallelBranch` | A fan-out node has no branch callbacks. |
| `EmptyDefinitionId` / `DefinitionIdTooLong` | An enabled graph persistence identity is empty or exceeds its bound. |
| `DuplicateStart` / `DuplicateEnd` | A boundary callback was registered twice. |
| `MissingStart` / `MissingEnd` / `MissingEntry` | A required graph boundary is absent. |
| `MissingOutgoingEdge` | A node has no following node or terminal route. |
| `DuplicateOutgoingEdge` | A core step has more than one route. |
| `UnreachableNode` | A registered node cannot be reached from the entry. |
| `LimitExceeded` | A node, edge, or parallel-branch registration exceeds the graph ceiling. |
| `StepLimitExceeded` | A run reached its bounded transition count. |
| `FanOutLimitExceeded` | A map emitted too many values or would create too many branch tasks. |
| `InvalidRunOptions` | The requested graph concurrency is zero or the definition disables execution. |
| `ParallelExecutionRequiresIo` | A concurrent fan-out has no `std.Io` runtime. |
| `ParallelExecutionUnavailable` | The runtime could not admit a fan-out callback. |
| `UnmatchedRoute` | A decision returned a branch name that it did not register. |
| `RunFinished` | A caller advanced a run after it returned its output. |
| `StepFailed` / `Cancelled` | An application node failed or cooperatively cancelled. |

Graph snapshot operations additionally report:

| Error | Meaning |
| --- | --- |
| `InvalidSnapshot` | The envelope, stored payload, or frontier invariants are malformed. |
| `SnapshotLimitExceeded` | A snapshot exceeds its byte, value, depth, or collection ceiling. |
| `SnapshotsDisabled` | The graph has no stable `definition_id`. |
| `UnsupportedSnapshotVersion` | The envelope version is not supported. |
| `UnsupportedSnapshotPayloadVersion` | The stored payload schema is newer than the supplied codec. |
| `SnapshotDefinitionMismatch` | The snapshot fingerprint belongs to another graph definition. |
| `SnapshotUnavailable` | The run is complete, failed, or otherwise not at a settled running boundary. |
| `SnapshotMigrationRequired` | An older payload has no migration callback. |
| `InvalidSnapshotCodec` | The supplied codec uses the reserved version zero. |
| `SnapshotStepLimitExceeded` | A requested resume ceiling is below the completed step count. |
| `SnapshotCodecFailed` | An application encoder, decoder, or migration rejected its input. |

## MCP errors

| Error | Meaning |
| --- | --- |
| `EmptyCommand` | A stdio transport has no program command. |
| `HeaderMismatch` | A header value violates its schema annotation. |
| `InputRequired` | Elicitation needs input but no handler supplied it. |
| `InvalidMcpHeaderAnnotation` | Tool header annotations are malformed. |
| `InvalidMcpMessage` | A JSON-RPC message is malformed. |
| `InvalidMcpResponse` | A result does not match its method shape. |
| `InvalidMcpToolArguments` | Tool arguments are not a bounded JSON object. |
| `InvalidMcpTransportConfiguration` | An MCP transport concurrency or buffering limit is invalid. |
| `InvalidTaskStore` | A durable task snapshot is malformed or has an unsupported version. |
| `McpHttpRequestFailed` | Streamable HTTP returned a non-success response. |
| `McpMessageTooLarge` | An MCP message exceeded its byte limit. |
| `McpPaginationCursorCycle` | A paginated collection repeated a cursor. |
| `McpProcessClosed` | A stdio child closed before the matching response. |
| `McpResponseIdMismatch` | A response ID does not match the request. |
| `McpRpcError` | The peer returned a JSON-RPC error envelope. |
| `McpStdioBackpressure` | A stdio transport reached its pending-request bound. |
| `MissingMcpClient` | An MCP toolset has no client. |
| `MissingMcpClientCapability` | A Tasks operation was attempted without the extension capability. |
| `MissingMcpTaskStore` | Durable task resumption was requested without a store. |
| `DurableMcpEventsRequireRouting` | A durable subscription used a process-local sink, or durable event delivery lacked a durable request. |
| `MissingDurableEventHandler` | Durable subscription delivery has no registered event worker. |
| `DurableOperationFailed` | An MCP durable worker returned a persisted failure. |
| `DurableOperationSuspended` | An MCP durable worker returned a persisted suspension. |
| `DurableSequenceExhausted` | A sequential MCP durable identity source exhausted `u64`. |
| `MissingMcpSseResponse` | Streamable HTTP did not produce the required SSE stream. |
| `SubscriptionRecoveryRequiresIo` | A nonzero subscription recovery delay has no I/O runtime. |
| `TaskPollingRequiresIo` | A nonzero task polling delay has no I/O runtime. |
| `TaskStoreTooLarge` | A durable task snapshot exceeded its configured byte bound. |
| `TooManyMcpPages` | Tool discovery exceeded the configured page limit. |
| `TooManyMcpRoundTrips` | Elicitation exceeded its round-trip limit. |
| `TooManyMcpTaskPolls` | A task remained non-terminal after its bounded polling budget. |
| `UnsupportedMcpProtocolVersion` | Discovery negotiated an unsupported revision. |

## Application errors

Tool functions, lifecycle hooks, stream sinks, dynamic instructions, history
processors, selectors, evaluators, transports, telemetry exporters, diagnostic
sinks, and MCP handlers may return application-defined errors. ZigAI propagates
them unchanged.
They are intentionally not converted to `ProviderConnectionError` or another
framework category.

The public callback contracts are split deliberately:

| Callback | Contract | Reason |
| --- | --- | --- |
| Provider error observer | Infallible | Observation cannot change request control flow. |
| Token estimator | Infallible | It performs borrowed, allocation-free counting. |
| Tool recovery classifier | Infallible | It classifies an error already produced. |
| Tool, model, and transport operations | Fallible | They perform application or external I/O work. |
| Stream, lifecycle, retry, telemetry, and diagnostic sinks | Fallible | Applications may stop a run when delivery fails. |
| Instructions, history, toolsets, selectors, and evaluators | Fallible | They may allocate or call application services. |
| MCP handlers and event sinks | Fallible | They cross application and protocol boundaries. |

This keeps `anyerror` only at extension points where preserving the
application's concrete error is part of the API. Framework-owned decisions use
the named sets above.
