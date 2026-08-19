/** Self-check for the event→hook mapping. Run: node --test test.js */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { eventToPost, messageText } from './index.js'

test('messageText joins text blocks and tolerates junk', () => {
  assert.equal(messageText({ content: [{ type: 'text', text: 'a' }, { type: 'tool-call' }, { type: 'text', text: 'b' }] }), 'a b')
  assert.equal(messageText({ content: 'plain' }), 'plain')
  assert.equal(messageText({ content: [{ type: 'text' }] }), '')
  assert.equal(messageText(undefined), '')
})

test('turn/start resets remembered text via UserPromptSubmit', () => {
  assert.deepEqual(eventToPost({ type: 'turn/start', data: { turn: 1 } }), { hook: 'UserPromptSubmit', text: '' })
})

test('assistant/message only remembers text, never posts', () => {
  assert.deepEqual(eventToPost({ type: 'assistant/message', data: { message: { content: [{ type: 'text', text: 'done!' }] } } }), { text: 'done!' })
  assert.equal(eventToPost({ type: 'assistant/message', data: { message: { content: [] } } }), undefined)
})

test('tool/result maps to heartbeat or failure', () => {
  const ok = { type: 'tool/result', data: { message: { content: [{ isError: false }] } } }
  assert.deepEqual(eventToPost(ok), { hook: 'PostToolUse' })
  const isError = { type: 'tool/result', data: { message: { content: [{ isError: true, type: 'text', text: 'boom' }] } } }
  assert.deepEqual(eventToPost(isError), { hook: 'PostToolUseFailure', body: { error: 'boom' } })
  const hard = { type: 'tool/result', data: { error: { name: 'Crash', code: 'X' }, message: { content: [] } } }
  assert.deepEqual(eventToPost(hard), { hook: 'PostToolUseFailure', body: { error: 'Crash' } })
})

test('approval/asked asks the human with tool + reason', () => {
  const mapped = eventToPost({ type: 'approval/asked', data: { id: 'a', toolName: 'bash', reason: 'needs write' } })
  assert.deepEqual(mapped, { hook: 'PermissionRequest', body: { message: 'bash: needs write' } })
})

test('turn/end: completed stops, error reports, others stay silent', () => {
  assert.deepEqual(eventToPost({ type: 'turn/end', data: { turn: 1, reason: { kind: 'completed' } } }), { hook: 'Stop', body: { text: '' } })
  const failed = eventToPost({ type: 'turn/end', data: { turn: 1, reason: { kind: 'error', error: { message: 'llm down', code: 'SERVER' } } } })
  assert.deepEqual(failed, { hook: 'PostToolUseFailure', body: { error: 'llm down' } })
  assert.equal(eventToPost({ type: 'turn/end', data: { turn: 1, reason: { kind: 'aborted', reason: { kind: 'legacy' } } } }), undefined)
})

test('unknown events and junk never throw, never post', () => {
  assert.equal(eventToPost({ type: 'todo/write', data: {} }), undefined)
  assert.equal(eventToPost(undefined), undefined)
  assert.equal(eventToPost({ type: 'tool/result', data: null }), undefined)
})
