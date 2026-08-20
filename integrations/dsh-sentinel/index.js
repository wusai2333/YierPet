/**
 * dsh-yierpet-sentinel — forwards dsh lifecycle events to YierPet.
 *
 * YierPet (macOS desktop pet) runs a loopback HTTP listener whose URL lives in
 * `~/.yierpet/endpoint`. This host-side plugin listens on dsh's durable
 * `session/event` firehose (the same seam the built-in pet consumes) and maps
 * the lifecycle moments onto YierPet's hook protocol:
 *
 *   turn/start            → UserPromptSubmit        (state reset)
 *   tool/result           → PostToolUse heartbeat, or PostToolUseFailure {error}
 *   approval/asked        → PermissionRequest {message}
 *   llm/retry             → PostToolUseFailure {error} (model rate-limit/error, retrying)
 *   turn/end completed    → Stop {text: last assistant reply}
 *   turn/end error        → PostToolUseFailure {error}
 *   session/disposed      → SessionEnd
 *
 * Iron rules: 1s timeout, every error swallowed, never blocks dsh. A missing
 * endpoint file (YierPet not running) skips the post silently. Subagent
 * sessions stay silent except approval asks — the main turn's Stop already
 * covers user-visible completion, and per-subagent bubbles would be noise.
 */

import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const name = 'dsh-yierpet-sentinel'
export const inject = []

const TIMEOUT_MS = 1000
/** Error bodies ride a 60-char bubble summary; 500 chars is ample and polite. */
const ERROR_CLIP = 500
/** Stop summaries show 60 chars; keep the body small. */
const TEXT_CLIP = 2000

function endpointUrl() {
  try {
    const url = readFileSync(join(homedir(), '.yierpet', 'endpoint'), 'utf8').trim()
    return url || null
  } catch {
    return null
  }
}

function clip(text, max) {
  return typeof text === 'string' && text.length > max ? `${text.slice(0, max)}…` : (text ?? '')
}

/** Join a message's text blocks (tolerates a plain-string content too). */
export function messageText(message) {
  const content = message?.content
  if (typeof content === 'string') return content.trim()
  if (!Array.isArray(content)) return ''
  return content
    .filter(block => block?.type === 'text' && typeof block.text === 'string')
    .map(block => block.text)
    .join(' ')
    .trim()
}

/**
 * Map one durable session event to a YierPet post.
 * @returns `undefined` when nothing posts; otherwise `{ hook, body?, text? }` —
 *   a present `text` replaces the session's remembered last-assistant text
 *   ('' on turn/start resets it), and a Stop body's `text` is filled by the
 *   caller from that remembered value.
 */
export function eventToPost(event) {
  const data = event?.data
  switch (event?.type) {
    case 'turn/start':
      return { hook: 'UserPromptSubmit', text: '' }
    case 'assistant/message': {
      const text = messageText(data?.message)
      return text ? { text } : undefined
    }
    case 'tool/result': {
      if (!data?.message) return undefined
      const block = data.message.content?.[0]
      if (data?.error !== undefined || block?.isError === true) {
        const error = clip(messageText(data?.message) || data?.error?.name || 'tool failed', ERROR_CLIP)
        return { hook: 'PostToolUseFailure', body: { error } }
      }
      return { hook: 'PostToolUse' }
    }
    case 'approval/asked': {
      const message = clip(`${data?.toolName ?? 'tool'}${data?.reason ? `: ${data.reason}` : ''}`, ERROR_CLIP)
      return { hook: 'PermissionRequest', body: { message } }
    }
    case 'llm/retry': {
      // Model-side failure the loop is retrying (rate limit, server, timeout):
      // surface as an error bubble — YierPet's 60s throttle keeps backoff
      // bursts (retries every few seconds) to at most one bubble per minute.
      const failure = data?.failure
      const delayS = Math.max(1, Math.round((data?.delayMs ?? 0) / 1000))
      const attempt = typeof data?.retry === 'number'
        ? ` (${data.retry}${typeof data.maxRetries === 'number' ? `/${data.maxRetries}` : ''})`
        : ''
      const error = clip(
        `模型报错 ${failure?.code ?? 'UNKNOWN'}${failure?.message ? `：${failure.message}` : ''}，${delayS}s 后重试${attempt}`,
        ERROR_CLIP,
      )
      return { hook: 'PostToolUseFailure', body: { error } }
    }
    case 'turn/end': {
      const reason = data?.reason
      if (reason?.kind === 'completed') return { hook: 'Stop', body: { text: '' } }
      if (reason?.kind === 'error') {
        return { hook: 'PostToolUseFailure', body: { error: clip(String(reason.error?.message ?? 'turn failed'), ERROR_CLIP) } }
      }
      return undefined
    }
    default:
      return undefined
  }
}

/** Fire-and-forget POST; silent on every failure, bounded by TIMEOUT_MS. */
function post(hook, cwd, body) {
  try {
    const url = endpointUrl()
    if (!url) return
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
    timer.unref?.()
    fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-YierPet-Tool': 'dsh',
        'X-YierPet-Hook': hook,
        'X-YierPet-Cwd': cwd,
      },
      body: JSON.stringify(body ?? {}),
      signal: controller.signal,
    }).catch(() => {}).finally(() => clearTimeout(timer))
  } catch {
    /* silent — the pet must never hurt the harness */
  }
}

export function apply(ctx) {
  /** Remembered last assistant text per live session. */
  const lastText = new WeakMap()
  const isSubagent = session => session?.header?.origin === 'subagent'
  const cwdOf = session => (typeof session?.header?.cwd === 'string' ? session.header.cwd : process.cwd())

  ctx.on('session/event', (session, event) => {
    try {
      const mapped = eventToPost(event)
      if (mapped === undefined) return
      if (mapped.text !== undefined) {
        if (!isSubagent(session)) lastText.set(session, mapped.text)
      }
      if (mapped.hook === undefined) return
      if (mapped.hook === 'PermissionRequest') {
        // A human must act regardless of which session asks.
        post(mapped.hook, cwdOf(session), mapped.body)
        return
      }
      if (isSubagent(session)) return
      if (mapped.hook === 'Stop') mapped.body.text = clip(lastText.get(session) ?? '', TEXT_CLIP)
      post(mapped.hook, cwdOf(session), mapped.body)
    } catch {
      /* silent */
    }
  })

  ctx.on('session/disposed', (session) => {
    try {
      if (!isSubagent(session)) post('SessionEnd', cwdOf(session))
    } catch {
      /* silent */
    }
  })
}
