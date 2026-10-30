import { Plugin } from "@opencode/plugin"
import { spawn } from "node:child_process"
import { homedir } from "node:os"
import { join } from "node:path"

const repo = join(homedir(), "ai-memories")
const sync = join(repo, "hooks", "memory-sync.sh")
const every = Number(process.env.OPENCODE_MEMORY_CHECKPOINT_EVERY || 6)
const checkpointText =
  "MEMORY CHECKPOINT: if this session established durable facts that are not already in ~/ai-memories, write them now (one fact per file, MEMORY.md pointer, absolute date, sourced, no secrets) and mention each write in one line. Do not run git yourself; memory-sync.sh save is the only commit path."

function run(args: string[], stdin?: string): Promise<string> {
  return new Promise((resolve) => {
    const child = spawn(sync, args, { stdio: ["pipe", "pipe", "pipe"] })
    let out = ""
    const timer = setTimeout(() => {
      child.kill("SIGTERM")
      resolve(out.trim())
    }, 20_000)
    child.stdout.on("data", (chunk) => {
      out += chunk
    })
    child.on("error", () => {
      clearTimeout(timer)
      resolve("")
    })
    child.on("close", () => {
      clearTimeout(timer)
      resolve(out.trim())
    })
    if (stdin) child.stdin.write(stdin)
    child.stdin.end()
  })
}

function sessionIDOf(event: object): string | undefined {
  const record = event as { sessionID?: string; properties?: { sessionID?: string } }
  return record.sessionID ?? record.properties?.sessionID
}

export default Plugin.define({
  id: "ai-memories",
  async setup(ctx) {
    const counts = new Map<string, number>()
    const ready = new Set<string>()
    const checkpoint = new Set<string>()
    let saving = false

    const save = () => {
      if (saving) return
      saving = true
      void run(["save"]).finally(() => {
        saving = false
      })
    }
    const timer = setInterval(save, 3 * 60 * 1000)

    async function attach(sessionID: string) {
      if (!sessionID || ready.has(sessionID)) return
      let directory: string | undefined
      try {
        const session = (await ctx.session.get({ sessionID })) as {
          directory?: string
          data?: { directory?: string }
        }
        directory = session.directory ?? session.data?.directory
      } catch {
        return
      }
      if (!directory) return
      await run(["start"], JSON.stringify({ cwd: directory }))
      const folder = await run(["path", directory])
      if (!folder.startsWith(repo)) return
      ready.add(sessionID)
      await ctx.session.instructions.entry
        .put({
          sessionID,
          key: "ai-memories",
          value: `Shared memory folder: ${folder}\nRead MEMORY.md there before other work. Write durable facts into that folder using ~/ai-memories/global/CLAUDE.md. Do not run git in ~/ai-memories; the plugin commits with memory-sync.sh save on idle and every 3 minutes.`,
        })
        .catch(() => {})
    }

    await ctx.session.hook("prompt", async (event) => {
      const sessionID = sessionIDOf(event)
      if (!sessionID) return
      const count = (counts.get(sessionID) ?? 0) + 1
      counts.set(sessionID, count)
      if (count % every === 0) checkpoint.add(sessionID)
      await attach(sessionID)
    })

    await ctx.session.hook("context", (event) => {
      const sessionID = sessionIDOf(event)
      if (!sessionID || !checkpoint.has(sessionID)) return
      checkpoint.delete(sessionID)
      event.system.push({ type: "text", text: checkpointText })
    })

    const controller = new AbortController()
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({
          signal: controller.signal,
          types: ["session.idle", "session.created"],
        })) {
          if (event.type === "session.idle") save()
          if (event.type === "session.created") void attach(sessionIDOf(event) ?? "")
        }
      } catch {
        // The stream ends when the plugin unloads.
      }
    })()

    return () => {
      clearInterval(timer)
      controller.abort()
      save()
    }
  },
})
