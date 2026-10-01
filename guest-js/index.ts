import { Channel } from '@tauri-apps/api/core'
import { commands, type CloudKitEvent } from './bindings'
export * from './bindings'

/** Unwrap a generated command result, preserving the structured CloudKit error. */
export function unwrap<T, E>(result: { status: 'ok'; data: T } | { status: 'error'; error: E }): T {
  if (result.status === 'error') throw result.error
  return result.data
}

/** Requires allow-subscribe-events and allow-unsubscribe-events. Read pending
 * invitations after subscribing so startup events cannot be missed. */
export async function onCloudKitEvent(handler: (event: CloudKitEvent) => void): Promise<() => Promise<void>> {
  const channel = new Channel<CloudKitEvent>()
  channel.onmessage = handler
  const id = unwrap(await commands.subscribeEvents(channel))
  let active = true
  return async () => {
    if (!active) return
    unwrap(await commands.unsubscribeEvents(id))
    active = false
  }
}
