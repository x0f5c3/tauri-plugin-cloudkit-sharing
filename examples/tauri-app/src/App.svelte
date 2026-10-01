<script lang="ts">
  import { onMount } from 'svelte'
  import type {
    Record,
    Share,
    ZoneId,
    DatabaseScope,
    Invitation,
    WritePermission,
    Permission,
  } from 'tauri-plugin-cloudkit-sharing-api'
  import { commands, unwrap, onCloudKitEvent } from 'tauri-plugin-cloudkit-sharing-api'

  interface LogEntry {
    time: string
    label: string
    text: string
  }

  let containerId = $state('iCloud.com.example.cloudkitsharing')
  let database = $state<DatabaseScope>('private')
  let zoneName = $state('SharedNotes')
  let ownerName = $state('__defaultOwner__')
  let recordName = $state('note-1')
  let body = $state('A note to write together.')
  let model = $state<'record' | 'zone'>('record')
  let zones = $state<ZoneId[]>([])
  let records = $state<Record[]>([])
  let current = $state<Record | null>(null)
  let share = $state<Share | null>(null)
  let shareName = $state('')
  let pending = $state<Invitation[]>([])
  let url = $state('')
  let participantId = $state('')
  let email = $state('')
  let permission = $state<WritePermission>('readWrite')
  let publicPermission = $state<Permission>('none')
  let logs = $state<LogEntry[]>([])
  let busy = $state(false)
  let cursor = $state<string | null>(null)

  const zone = (): ZoneId => ({ zoneName, ownerName })
  const scope = () => ({ containerId, database })
  const shareId = () => ({ recordName: shareName, zoneId: zone() })

  const log = (label: string, value: unknown) => {
    logs = [
      {
        time: new Date().toLocaleTimeString(),
        label,
        text: typeof value === 'string' ? value : JSON.stringify(value, null, 2),
      },
      ...logs,
    ].slice(0, 60)
  }

  async function run(label: string, fn: () => Promise<unknown>) {
    if (busy) return
    busy = true
    try {
      const value = await fn()
      log(label, value ?? 'Done')
    } catch (error) {
      log(label + ' failed', error instanceof Error ? error.message : error)
    } finally {
      busy = false
    }
  }

  async function inbox() {
    pending = unwrap(await commands.pendingInvitations())
    return pending
  }

  function selectZone(value: ZoneId) {
    zoneName = value.zoneName
    ownerName = value.ownerName
    current = null
    records = []
    cursor = null
    share = null
    shareName = ''
  }

  function selectRecord(value: Record) {
    current = value
    recordName = value.recordId.recordName
    body = value.fields.body?.type === 'string' ? value.fields.body.value : ''
  }

  function useShare(value: Share) {
    share = value
    shareName = value.recordId.recordName
    zoneName = value.recordId.zoneId.zoneName
    ownerName = value.recordId.zoneId.ownerName
    publicPermission = value.publicPermission
    return value
  }

  function note(): Record {
    if (
      current &&
      (current.recordId.recordName !== recordName ||
        JSON.stringify(current.recordId.zoneId) !== JSON.stringify(zone()))
    ) {
      throw new Error('Fetch the selected record before editing it, or choose New note.')
    }
    return current
      ? {
          ...current,
          fields: {
            ...current.fields,
            body: { type: 'string', value: body },
          },
        }
      : {
          recordId: { recordName, zoneId: zone() },
          recordType: 'SharedNote',
          fields: { body: { type: 'string', value: body } },
          parent: null,
          systemFields: null,
        }
  }

  async function save() {
    const value = unwrap(
      await commands.modifyRecords({
        ...scope(),
        records: [note()],
        deleteIds: [],
        savePolicy: 'ifServerRecordUnchanged',
        atomic: true,
      })
    )
    if (value.saved[0]) selectRecord(value.saved[0])
    return value
  }

  async function query(more = false) {
    const value = unwrap(
      await commands.queryRecords({
        ...scope(),
        zoneId: zone(),
        recordType: 'SharedNote',
        filters: [],
        sort: [],
        limit: 100,
        cursor: more ? cursor : null,
      })
    )
    records = more ? [...records, ...value.records] : value.records
    cursor = value.cursor
    return value
  }

  async function createShare() {
    if (database !== 'private') throw new Error('Create shares in the owner’s private database.')
    let shareTargetRecord = current
    if (model === 'record') {
      const saveRes = await save()
      shareTargetRecord = saveRes.saved[0] ?? current
      if (!shareTargetRecord) {
        throw new Error('Could not save note before creating record share.')
      }
    }
    return useShare(
      unwrap(
        await commands.createShare({
          containerId,
          target:
            model === 'record'
              ? { type: 'record', record: shareTargetRecord! }
              : { type: 'zone', zoneId: zone() },
          title: 'Shared notes',
          shareType: null,
          thumbnail: null,
          publicPermission: 'none',
        })
      )
    )
  }

  async function accept(invitation: Invitation) {
    const value = unwrap(await commands.acceptInvitation({ invitationId: invitation.id }))
    containerId = invitation.containerId
    database = 'shared'
    selectZone(value.recordId.zoneId)
    useShare(value)
    if (invitation.rootRecordId) recordName = invitation.rootRecordId.recordName
    await inbox()
    return value
  }

  onMount(() => {
    let disposed = false
    let unsubscribe: (() => Promise<void>) | undefined
    onCloudKitEvent((event) => {
      log(event.kind, event)
      if (event.kind === 'invitationReceived' || event.kind === 'shareAccepted') {
        inbox().catch((error) => log('Inbox', error))
      }
    })
      .then((fn) => {
        if (disposed) void fn()
        else unsubscribe = fn
      })
      .catch((error) => log('Subscribe', error))
    inbox().catch((error) => log('Inbox', error))
    return () => {
      disposed = true
      if (unsubscribe) void unsubscribe()
    }
  })
</script>

<main>
  <header>
    <p class="eyebrow">Tauri · CloudKit sharing</p>
    <h1>Shared notes</h1>
    <p>
      A signed Apple app and your own iCloud container are required. Replace the example container in
      the host configuration and entitlements first.
    </p>
  </header>

  <fieldset disabled={busy}>
    <legend>1. Account and database</legend>
    <label>
      Container
      <input bind:value={containerId} />
    </label>
    <label>
      Database
      <select
        bind:value={database}
        onchange={() => {
          current = null
          share = null
          records = []
          zones = []
          cursor = null
        }}
      >
        <option value="private">Private — owner</option>
        <option value="shared">Shared — participant</option>
      </select>
    </label>
    <div class="actions">
      <button onclick={() => run('Capabilities', async () => unwrap(await commands.capabilities()))}>
        Capabilities
      </button>
      <button onclick={() => run('Account', async () => unwrap(await commands.accountStatus({ containerId })))}>
        Check account
      </button>
      <button onclick={() => run('Zones', async () => (zones = unwrap(await commands.listZones(scope()))))}>
        Discover zones
      </button>
    </div>
    {#each zones as item}
      <button class="choice" onclick={() => selectZone(item)}>
        {item.zoneName} · {item.ownerName}
      </button>
    {/each}
    <label>
      Zone name
      <input bind:value={zoneName} />
    </label>
    <label>
      Zone owner
      <input bind:value={ownerName} />
    </label>
    <p class="hint">
      Keep the returned owner identifier when accessing another person’s shared zone.
    </p>
    <button
      disabled={database !== 'private'}
      onclick={() =>
        run('Create zone', async () =>
          unwrap(await commands.createZone({ ...scope(), zoneId: zone() }))
        )}
    >
      Create owner zone
    </button>
  </fieldset>

  <fieldset disabled={busy}>
    <legend>2. Read and edit notes</legend>
    <div class="actions">
      <button onclick={() => run('Query notes', () => query())}>List notes</button>
      <button disabled={!cursor} onclick={() => run('Next page', () => query(true))}>
        Next page
      </button>
      <button
        onclick={() => {
          current = null
          recordName = 'note-' + Date.now()
          body = ''
        }}
      >
        New note
      </button>
    </div>
    {#each records as item}
      <button class="choice" onclick={() => selectRecord(item)}>
        {item.recordId.recordName}
      </button>
    {/each}
    <label>
      Record name
      <input bind:value={recordName} />
    </label>
    <button
      onclick={() =>
        run('Fetch note', async () => {
          const values = unwrap(
            await commands.fetchRecords({
              ...scope(),
              recordIds: [{ recordName, zoneId: zone() }],
            })
          )
          if (values[0]) selectRecord(values[0])
          return values
        })}
    >
      Fetch by name
    </button>
    <label>
      Note
      <textarea rows="4" bind:value={body}></textarea>
    </label>
    <p class="hint">
      Fetch or select an existing note before saving to preserve its version. A conflict is shown in
      the log; it is never silently overwritten.
    </p>
    <button onclick={() => run('Save note', save)}>Save note</button>
  </fieldset>

  <fieldset disabled={busy}>
    <legend>3. Create and manage a share</legend>
    <label>
      Sharing model
      <select bind:value={model}>
        <option value="record">Record hierarchy — current note is root</option>
        <option value="zone">Whole zone — every note in this zone</option>
      </select>
    </label>
    <p class="hint">
      Use separate zones to try the two models. Creating a root share first saves the current note.
    </p>
    <button disabled={database !== 'private'} onclick={() => run('Create share', createShare)}>
      Create share
    </button>
    <label>
      Share record name
      <input bind:value={shareName} />
    </label>
    <div class="actions">
      <button
        disabled={!shareName}
        onclick={() =>
          run('Fetch share', async () =>
            useShare(unwrap(await commands.fetchShare({ ...scope(), shareId: shareId() })))
          )}
      >
        Fetch share
      </button>
      <button
        disabled={!shareName}
        onclick={(event) => {
          const rect = (event.currentTarget as HTMLElement).getBoundingClientRect()
          run('Sharing UI', async () =>
            unwrap(
              await commands.presentSharingUi({
                ...scope(),
                shareId: shareId(),
                windowLabel: 'main',
                anchor: {
                  x: rect.x,
                  y: rect.y,
                  width: rect.width,
                  height: rect.height,
                },
              })
            )
          )
        }}
      >
        Open native sharing UI
      </button>
    </div>
    {#if share?.url}
      <p>Invitation URL: <a href={share.url} rel="noreferrer">{share.url}</a></p>
    {/if}
    <label>
      Public access
      <select bind:value={publicPermission}>
        <option value="none">Invited people only</option>
        <option value="readOnly">Anyone with link — read only</option>
        <option value="readWrite">Anyone with link — read/write</option>
      </select>
    </label>
    <button
      disabled={!share || database !== 'private'}
      onclick={() =>
        run('Update share', async () =>
          useShare(
            unwrap(
              await commands.updateShare({
                containerId,
                shareId: shareId(),
                title: share?.title ?? null,
                shareType: share?.shareType ?? null,
                thumbnail: null,
                publicPermission,
              })
            )
          )
        )}
    >
      Apply public access
    </button>
    <p class="hint">
      This example creates no thumbnails; updating metadata clears any existing thumbnail.
    </p>
    {#if share}
      <ul>
        {#each share.participants as person}
          <li>
            <button onclick={() => (participantId = person.participantId)}>
              {person.displayName ?? person.participantId}
            </button>
            {person.role} · {person.permission} · {person.acceptanceStatus}
          </li>
        {/each}
      </ul>
    {/if}
    <label>
      Participant permission
      <select bind:value={permission}>
        <option value="readWrite">Read/write</option>
        <option value="readOnly">Read only</option>
      </select>
    </label>
    <label>
      Invite by email
      <input type="email" bind:value={email} />
    </label>
    <button
      disabled={!shareName || !email || database !== 'private'}
      onclick={() =>
        run('Add participant', async () =>
          useShare(
            unwrap(
              await commands.addParticipant({
                containerId,
                shareId: shareId(),
                lookup: { type: 'email', value: email },
                permission,
              })
            )
          )
        )}
    >
      Add participant
    </button>
    <label>
      Selected participant ID
      <input bind:value={participantId} />
    </label>
    <div class="actions">
      <button
        disabled={!shareName || !participantId || database !== 'private'}
        onclick={() =>
          run('Permission', async () =>
            useShare(
              unwrap(
                await commands.setParticipantPermission({
                  containerId,
                  shareId: shareId(),
                  participantId,
                  permission,
                })
              )
            )
          )}
      >
        Set permission
      </button>
      <button
        disabled={!shareName || !participantId || database !== 'private'}
        onclick={() =>
          run('Remove participant', async () =>
            useShare(
              unwrap(
                await commands.removeParticipant({
                  containerId,
                  shareId: shareId(),
                  participantId,
                })
              )
            )
          )}
      >
        Remove participant
      </button>
    </div>
    <div class="actions">
      <button
        disabled={!shareName || database !== 'shared'}
        onclick={() =>
          run('Leave share', async () => {
            unwrap(await commands.leaveShare({ containerId, shareId: shareId() }))
            share = null
            shareName = ''
          })}
      >
        Leave as participant
      </button>
      <button
        disabled={!shareName || database !== 'private'}
        onclick={() =>
          run('Stop sharing', async () => {
            unwrap(await commands.stopSharing({ containerId, shareId: shareId() }))
            share = null
            shareName = ''
          })}
      >
        Stop sharing as owner
      </button>
    </div>
  </fieldset>

  <fieldset disabled={busy}>
    <legend>4. Accept an invitation</legend>
    <label>
      Invitation URL
      <input type="url" bind:value={url} />
    </label>
    <div class="actions">
      <button
        disabled={!url}
        onclick={() =>
          run('Fetch invitation', async () => {
            const value = unwrap(await commands.fetchInvitation({ containerId, url }))
            await inbox()
            return value
          })}
      >
        Fetch invitation metadata
      </button>
      <button onclick={() => run('Pending invitations', inbox)}>Refresh inbox</button>
    </div>
    {#each pending as invitation}
      <article>
        <p>{invitation.share.title ?? invitation.id} · {invitation.containerId}</p>
        <button onclick={() => run('Accept invitation', () => accept(invitation))}>Accept</button>
        <button
          onclick={() =>
            run('Dismiss invitation', async () => {
              unwrap(await commands.dismissInvitation({ invitationId: invitation.id }))
              await inbox()
            })}
        >
          Dismiss
        </button>
      </article>
    {/each}
    <p class="hint">
      Acceptance switches to the shared database. Discover zones or fetch the invited root by name,
      then edit as permitted.
    </p>
  </fieldset>

  <section aria-live="polite">
    <div class="actions">
      <h2>Activity {busy ? '· working…' : ''}</h2>
      <button onclick={() => (logs = [])}>Clear log</button>
    </div>
    {#each logs as entry}
      <article>
        <strong>{entry.time} · {entry.label}</strong>
        <pre>{entry.text}</pre>
      </article>
    {/each}
  </section>
</main>
