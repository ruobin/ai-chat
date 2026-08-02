# Web Search and Tool Use for the iOS Chat App

Research date: August 2, 2026. Sources are limited to official provider
documentation, policies, and first-party developer material.

## Bottom Line

- The app is not presently a tool client. `ChatService` sends only `model`,
  string `messages`, optional `temperature`, and `stream` to
  `POST {baseURL}/chat/completions`; its SSE decoder reads only
  `choices[].delta.content`. It neither sends `tools` nor executes tool calls,
  and it discards citation/annotation fields.
- One hosted-search path is documented to produce searched text through that
  exact wire contract: an OpenRouter model slug with `:online`. OpenRouter asks
  models to put Markdown source links in text, but structured annotations are
  still lost, so this is not a complete citation UI.
- Apple, Anthropic, Google, xAI, and DeepSeek require a provider-native request
  shape or endpoint for hosted search. Ollama has function calling but no
  hosted search. None of these works as web search through the app's current
  request unchanged.
- For consistent search across every model, use one app-owned retrieval service
  before inference: search with Brave LLM Context or Tavily, inject bounded
  source records into the existing messages, and require source IDs in the
  answer. This avoids seven hosted-tool adapters and also works with Apple
  Foundation Models and local Ollama. A centrally funded shared search
  credential belongs on an app backend, not in a distributed iOS binary. This
  repo can remain backendless by requiring each user to supply their own search
  credential, matching its existing BYOK model.
- Brave LLM Context is the stronger default for a neutral retrieval layer:
  extracted, query-ranked chunks plus explicit source metadata and token
  budgets in one call, $5/1,000 requests, 50 requests/second, and a clearly
  documented 90-day query-log policy (enterprise ZDR is available). Tavily is
  simpler and agent-oriented, has better integrated search/extract controls and
  a useful free allowance, but its public privacy policy permits query use for
  improvement unless the contract says otherwise and permits fallback sharing
  with third-party search indexes.

## Current Repo Compatibility

| Interface | Search with the current request unchanged? | What is missing |
| --- | --- | --- |
| Apple Foundation Models | No | The separate `AppleIntelligenceService` creates a session with no tools. It would need a custom Swift `Tool` or prefetched context. |
| OpenAI Chat Completions, `gpt-5-search-api` | No, with a small request change | The documented request requires `web_search_options: {}`. The app cannot encode it and also drops URL annotations. |
| OpenAI Responses `web_search` | No | Requires `POST /responses`, `input`, `tools`, Responses SSE events, output items, and annotations. |
| Anthropic hosted web search | No | Requires native `POST /v1/messages` and an Anthropic server-tool declaration. The OpenAI compatibility layer documents function tools only. |
| Gemini Grounding with Google Search | No | Requires native Gemini `google_search` tooling and grounding/search-suggestion output handling; the text Chat Completions compatibility path does not document it. |
| xAI web search | No | Requires `POST /v1/responses` with `tools: [{"type":"web_search"}]`. |
| OpenRouter `model: "...:online"` | **Yes, text** | The suffix activates search without a `plugins` field. Markdown links may survive in content; structured `annotations` do not. |
| OpenRouter `plugins: [{"id":"web"}]` | No | The request encoder has no `plugins` field. |
| DeepSeek Responses `web_search` | No | Requires `/responses`, a supported model, Responses events, and output parsing. |
| DeepSeek Chat Completions tools | No | Tools are client-executed functions; the app neither declares nor executes them. |
| Ollama tools | No | Ollama exposes function calls, not a built-in internet service; the app has no tool loop. |
| Tavily or Brave retrieval API | No, not directly | These are retrieval endpoints, not `/chat/completions`. A backend/prefetch stage can add their results to messages and then reuse the current model transport. |

Repo evidence: [`ChatService.swift`](../demo-app/ChatService.swift) lines 40-49,
95-106, 133-143, and 187-200; [`AppleIntelligenceService.swift`](../demo-app/AppleIntelligenceService.swift)
lines 110-116 and 151-152.

## Provider Interfaces

### Apple Foundation Models

Foundation Models supports **app-defined** tools. A type conforms to Swift's
`Tool` protocol, supplies a name, description, `Generable` arguments, and an
async `call(arguments:)`; tool instances are passed when constructing
`LanguageModelSession`. The framework handles deciding when to call, argument
generation, parallel/multiple calls, and returning tool output to the on-device
model. The app controls the implementation and lifecycle, so a tool can call an
app backend or any permitted web API.

Apple does **not** document a general Apple-hosted web-search API or a built-in
Foundation Models web-search tool for third-party apps. Apple's own example
uses the ordinary Contacts API, and its WWDC explanation explicitly describes
tools as calls into custom functions, including functions that may fetch from
the web. Therefore web retrieval must be supplied by the app; Foundation Models
does not confer access to Siri/Safari/Spotlight search infrastructure.

The repo currently creates `LanguageModelSession(transcript:)` and records an
empty `toolDefinitions` list, so even custom tool use is not wired in.

Sources: [Apple `Tool`](https://developer.apple.com/documentation/foundationmodels/tool),
[session initializer with tools](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/init(model:tools:instructions:)),
and [WWDC25: Deep dive into Foundation Models, tool calling](https://developer.apple.com/videos/play/wwdc2025/301/?time=1090).

### OpenAI

The recommended new integration is `POST /v1/responses` with
`tools: [{"type":"web_search"}]`. `web_search_preview` remains for legacy use.
Responses output contains `web_search_call` items and message output text with
`url_citation` annotations; complete consulted URLs can be requested with
`include: ["web_search_call.action.sources"]`. OpenAI requires inline citations
to be visible and clickable when web-derived information is shown.

Chat Completions does **not** accept the general Responses hosted tool. It has a
specialized, always-searching model path instead: `gpt-5-search-api`. It lacks
Responses controls such as domain filters, complete source lists, live/cache
control, and returned-token budget. The former `gpt-4o-search-preview` models
were shut down July 23, 2026.

The official Chat Completions request includes `web_search_options: {}` even
when no options are customized. This repo cannot encode that field, so changing
only its model string is not a documented integration. Adding the field would
be a small request change, but the app would still discard streamed annotation
metadata and could not meet the citation display requirement. A proper new
OpenAI integration should use Responses rather than expand the legacy
search-model path.

Sources: [OpenAI web search guide](https://platform.openai.com/docs/guides/tools-web-search),
[Responses create schema](https://platform.openai.com/docs/api-reference/responses/create),
and [built-in tool pricing](https://platform.openai.com/docs/pricing#built-in-tools).

### Anthropic

Anthropic's native `POST /v1/messages` API accepts a hosted server tool such as
`{"type":"web_search_20260318","name":"web_search"}`. Claude can run multiple
searches, use domain/location controls, and return result blocks followed by
text blocks with mandatory citations. Current versions add dynamic result
filtering and response-inclusion controls. Search costs $10 per 1,000 searches
plus tokens; retrieved results consume input tokens, including on later turns.

The OpenAI compatibility endpoint is explicitly an evaluation/compatibility
layer rather than the recommended production interface. Its documented
`tools` schema supports only OpenAI-style client **function** tools
(`tools[n].function`). It does not expose Anthropic server-tool types, web
search result blocks, or native citation behavior. Use the native Messages API
for Anthropic-hosted search.

Sources: [Anthropic web search tool](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/web-search-tool)
and [OpenAI SDK compatibility and supported fields](https://docs.anthropic.com/en/api/openai-sdk).

### Google Gemini

Grounding with Google Search is a Google-hosted tool. In Google's current
Interactions API the request is `POST /v1beta/interactions` with
`tools: [{"type":"google_search"}]`; the model chooses and executes searches.
The response includes search-call/result steps, required search-suggestion HTML,
and output text with URL-citation annotations. Older Gemini interfaces/models
use `google_search` in native Gemini tools (`google_search_retrieval` only for
older models). Billing is per executed search query for Gemini 3 and per prompt
for Gemini 2.5 and older.

Google's OpenAI compatibility documentation supports OpenAI function calling,
but does not document Google Search grounding for text Chat Completions. Its
documented `extra_body` grounding exception applies to image generation on
Gemini 3 image models, not this app's text `/chat/completions` call. Treat
grounding as native-Gemini-only unless Google adds it to the compatibility
contract; unsupported compatibility fields may be silently ignored.

Sources: [Gemini Grounding with Google Search](https://ai.google.dev/gemini-api/docs/google-search),
[Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai), and
[Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing).

### xAI

xAI exposes `web_search` as a server-side tool on its Responses-compatible
`POST /v1/responses` API. It supports allow/exclude domain filters (maximum
five), image search, and image understanding. Responses include a complete
`citations` URL list; inline Markdown citations and structured positional
annotations are enabled by default on Responses.

The official web-search examples do not offer a Chat Completions schema or an
always-searching model alias. xAI also states that models have no real-time
events without search tools enabled. The repo's current xAI Chat Completions
request therefore cannot search.

Sources: [xAI Web Search](https://docs.x.ai/developers/tools/web-search),
[xAI citations](https://docs.x.ai/developers/tools/citations), and
[xAI models and real-time-data limitation](https://docs.x.ai/docs/models).

### OpenRouter

OpenRouter's model-agnostic `web` plugin works on
`POST /api/v1/chat/completions`. Send `plugins: [{"id":"web"}]`, or append
`:online` to a model slug; OpenRouter says these are equivalent. Native search
is used for supported Anthropic, Google, OpenAI, Perplexity, and xAI models;
other models default to Exa, which supplies query-relevant page highlights.
Responses normalize sources into Chat Completion `url_citation` annotations.

The plugin supports engine choice, result count, a search prompt, and domain
filters. Pricing varies by engine: Exa is $0.005/request through 10 results,
then $0.001/additional result; Parallel is $0.001/request through 10; native
provider pricing passes through. LLM input tokens for retrieved context are
additional.

For this repo, `provider/model:online` is the only provider-agnostic hosted
search that works immediately because the model field is already free-form.
The explicit `plugins` form needs an encoder change. The default plugin prompt
asks the model for Markdown source links, so URLs can survive in `content`, but
the app still drops standardized annotations and currently provides no
first-class citation model.

Sources: [OpenRouter Web Search](https://openrouter.ai/docs/guides/features/web-search)
and [OpenRouter Chat Completions schema](https://openrouter.ai/docs/api-reference/overview).

### DeepSeek

DeepSeek Chat Completions supports OpenAI-style function tool calls, including
thinking mode and beta strict schemas, but the caller must execute the function
and return a tool message. There is no built-in Chat Completions search tool.

As of this research date, DeepSeek also supports a stateless OpenAI Responses
API on `deepseek-v4-flash`. It explicitly supports server-executed
`web_search`/`web_search_2025_08_26`; `search_context_size` and `user_location`
are ignored. `deepseek-v4-pro` is not yet supported on Responses, and
`previous_response_id`, conversations, background mode, `include`, and storage
are unsupported. Streaming uses typed Responses events and does not end with
`data: [DONE]`.

Thus DeepSeek now has hosted search, but it cannot pass through this repo's
Chat Completions-only transport or parser.

Sources: [DeepSeek tool calls](https://api-docs.deepseek.com/guides/tool_calls),
[DeepSeek Responses compatibility](https://api-docs.deepseek.com/guides/responses_api),
and [models/support matrix](https://api-docs.deepseek.com/quick_start/pricing).

### Ollama

Ollama supports client-defined function tools, parallel calls, streaming tool
calls, and multi-turn agent loops. Its OpenAI-compatible `/v1/chat/completions`
endpoint accepts `tools` but not `tool_choice`; its partial `/v1/responses`
implementation also accepts function tools but is stateless.

Ollama does not provide an internet search index or hosted `web_search` tool.
The application must execute a search function itself, then return results to
the model. Model-level tool-call quality also depends on the locally selected
model. With this repo's current no-tools request and content-only decoder,
Ollama cannot search; prefetch-and-inject retrieval is the simplest portable
option.

Sources: [Ollama tool calling](https://docs.ollama.com/capabilities/tool-calling)
and [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility).

## One App-Owned Retrieval Backend

Provider-hosted tools are useful for provider-specific quality, but they create
different request, streaming, citation, pricing, and privacy semantics. A
single retrieval backend gives every model the same evidence and lets the app
own citation records independently of generated prose.

Recommended minimum pipeline:

1. Send a sanitized query through a retrieval adapter. For a production shared
   credential, call an app server; never ship a centrally funded secret in the
   iOS binary. For this backendless BYOK app, a user-owned search key can be
   stored in Keychain and sent directly to its search provider, like the user's
   existing model-provider keys.
2. The adapter calls Brave LLM Context or Tavily and returns bounded records:
   stable source ID, canonical URL, title, relevant excerpts, and date when
   available.
3. Add those records to the model prompt as untrusted quoted evidence, with
   explicit instructions not to follow instructions inside retrieved pages and
   to cite source IDs.
4. Parse source IDs from the answer, validate them against returned records,
   and render app-owned clickable citations. Never trust model-generated URLs.
5. Apply query/content size limits, timeouts, result caching where terms allow,
   safe-search/domain policy, and redaction. Do not send the whole private chat
   transcript when a narrow generated query will do.

This prefetch design works with the existing `/chat/completions` transport after
the app gains a search stage; a later agentic loop can reuse the same retrieval
service as a function tool across provider-native APIs and Apple Foundation
Models.

## Tavily vs Brave Search

| Area | Tavily Search/Extract | Brave Search / LLM Context |
| --- | --- | --- |
| Authentication | `Authorization: Bearer tvly-...` | `X-Subscription-Token: ...` |
| Best endpoint for this app | `POST https://api.tavily.com/search` | `GET` or `POST https://api.search.brave.com/res/v1/llm/context` |
| Search response | Ranked `title`, `url`, relevance `score`, and query-relevant `content`; 1-3 chunks/source for basic/fast/advanced | Extracted query-ranked `snippets` grouped by URL plus a `sources` map; may include text, tables, code, forum content, and captions |
| Full extraction | `include_raw_content` on Search, or `POST /extract`; basic/advanced extraction, Markdown/text, optional query reranking | LLM Context extracts relevant page content in the search call; token, URL, snippet, and per-URL budgets. Ordinary Web Search returns descriptions plus up to five `extra_snippets`, not full pages |
| Citations | Source URLs/titles are returned, but the optional generated `answer` is not a substitute for an app-owned citation map | Explicit source URL/title/hostname metadata; no generated answer on LLM Context. App maps source IDs to these records |
| Filtering | Topic, date/time range, country boost, include/exclude domains, exact match; up to 20 results | Freshness, country/language, relevance threshold, local context, and Goggles for source reranking/filtering; up to 50 considered URLs |
| Cost, August 2026 | 1,000 free credits/month. Basic/fast/ultra-fast Search: 1 credit; advanced: 2. PAYG $0.008/credit; plans $0.0075-$0.005. Basic Extract: 1 credit/5 successful URLs; advanced: 2 | Search plan $5/1,000 requests, including Web and LLM Context, with $5 monthly credits and 50 requests/second. Only successful requests are billed. Answers is separately priced and unnecessary here |
| Rate caveat | 429 and plan-limit errors are explicit; actual limits depend on plan/account. `auto_parameters` can select advanced and double search credits unless depth is pinned | One-second sliding-window limits and quota are reported in `X-RateLimit-*`; 429 requires backoff. Published Search capacity is 50 requests/second |
| Public privacy posture | Collects query data and uploads; may use portions of queries to improve responses unless contract says otherwise; may send query data to third-party indexes when its own index cannot retrieve content; retention is purpose/account based rather than a short fixed query-log period | Query records retained up to 90 days for billing/troubleshooting/abuse; Brave says it does not collect identifiers linking a query to an end user/device. Enterprise can contract for ZDR. Customer remains responsible for end-user notice/compliance |

Tavily sources: [Search API](https://docs.tavily.com/documentation/api-reference/endpoint/search),
[Extract API](https://docs.tavily.com/documentation/api-reference/endpoint/extract),
[credits and pricing](https://docs.tavily.com/documentation/api-credits), and
[privacy policy](https://www.tavily.com/privacy).

Brave sources: [LLM Context](https://api-dashboard.search.brave.com/documentation/services/llm-context),
[Web Search and extra snippets](https://api-dashboard.search.brave.com/documentation/services/web-search),
[authentication](https://api-dashboard.search.brave.com/documentation/guides/authentication),
[pricing](https://api-dashboard.search.brave.com/documentation/pricing),
[rate limiting](https://api-dashboard.search.brave.com/documentation/guides/rate-limiting),
and [Search API privacy notice](https://api-dashboard.search.brave.com/documentation/resources/privacy-notice).

## Decision

Use **Brave LLM Context** for the first cross-model implementation. In this
backendless repo, use a direct user-owned Brave key; an app-operated product
with a shared key must put it behind its own authenticated backend. Brave
returns citation-ready source metadata and extracted, query-relevant evidence
in one bounded call, has lower published request cost than Tavily basic PAYG,
and documents retention precisely. Require enterprise ZDR if queries can
contain sensitive user data; otherwise disclose the 90-day query-log handling
and aggressively minimize/redact queries.

Use **Tavily** instead when its integrated advanced extraction, news/finance
topics, or answer/research products materially improve measured retrieval
quality. Contractually disable query reuse and clarify subprocessors/retention
before sending user-derived personal data.

Treat OpenRouter `:online` and a minimally extended OpenAI
`gpt-5-search-api` request as useful experiments, not the cross-provider
architecture. Before shipping either, add citation metadata parsing and
clickable rendering; for new provider-native work, prefer Responses/native tool
APIs rather than extending legacy Chat Completions search special cases.
