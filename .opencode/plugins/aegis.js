import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { realpathSync } from "node:fs"
import { spawn } from "node:child_process"

const TOOL_NAMES = Object.freeze({
  bash: "Bash",
  edit: "Edit",
  write: "Write",
  read: "Read",
  glob: "Glob",
  grep: "Grep",
  list: "Glob",
  todowrite: "TodoWrite",
  task: "Task",
  webfetch: "WebFetch",
  websearch: "WebSearch",
})

const DECISIONS = new Set(["allow", "ask", "deny"])
const HANDLED_PERMISSIONS = Symbol.for("aegis.opencode.handledPermissions")
const handledPermissions = globalThis[HANDLED_PERMISSIONS] ??= new WeakSet()

function cacheKey(input) {
  const sessionID = typeof input?.sessionID === "string" ? input.sessionID : "unknown"
  const toolCallID = input?.tool && typeof input.tool === "object" ? input.tool.callID : undefined
  const callID = typeof toolCallID === "string" ? toolCallID : input?.callID
  return `${sessionID}:${callID}`
}

function normalizeToolName(input) {
  const raw = String(input?.permission ?? (typeof input?.tool === "string" ? input.tool : input?.type) ?? "")
  const mapped = TOOL_NAMES[raw.toLowerCase()]
  if (mapped) return mapped
  return raw ? raw.slice(0, 1).toUpperCase() + raw.slice(1) : "unknown"
}

function normalizeToolInput(toolName, input, cachedArgs) {
  const metadata = input?.metadata && typeof input.metadata === "object" ? input.metadata : {}
  const toolPayload = input?.tool && typeof input.tool === "object" ? input.tool : {}
  const source = cachedArgs ?? input?.args ?? toolPayload.input ?? toolPayload.args ?? metadata
  const args = source && typeof source === "object" ? { ...source } : {}

  if (toolName === "Bash") {
    const command = args.command ?? metadata.command ?? toolPayload.command ?? input?.command ?? ""
    return { command: String(command) }
  }

  if (toolName === "Edit" || toolName === "Write") {
    const filePath = args.file_path ?? args.filePath ?? args.path ?? metadata.filePath ?? metadata.path
    if (filePath) return { ...args, file_path: String(filePath) }
  }

  return args
}

function defaultAegisRoot() {
  const here = dirname(realpathSync(fileURLToPath(import.meta.url)))
  return resolve(here, "../..")
}

function buildHookPayload(input, cachedArgs, directory, aegisRoot) {
  const toolName = normalizeToolName(input)
  return {
    session_id: String(input?.sessionID ?? input?.sessionId ?? "opencode"),
    cwd: String(input?.cwd ?? directory ?? aegisRoot),
    tool_name: toolName,
    tool_input: normalizeToolInput(toolName, input, cachedArgs),
  }
}

function parseAegisDecision(result) {
  if (result.status === 2) {
    return { decision: "deny", reason: "aegis hard deny" }
  }
  if (result.status !== 0) {
    const reason = String(result.stderr ?? "").trim()
    return { decision: "ask", reason: reason || "aegis failed to classify the request" }
  }
  const stdout = String(result.stdout ?? "").trim()
  if (!stdout) {
    return { decision: "ask", reason: "aegis returned no decision" }
  }
  const parsed = JSON.parse(stdout)
  const hook = parsed.hookSpecificOutput ?? {}
  const decision = String(hook.permissionDecision ?? "ask")
  return {
    decision: DECISIONS.has(decision) ? decision : "ask",
    reason: typeof hook.permissionDecisionReason === "string" ? hook.permissionDecisionReason : "",
  }
}

async function replyPermission(client, requestID, sessionID, reply) {
  if (client?.permission?.reply) {
    return client.permission.reply({ requestID, reply })
  }
  if (client?._client?.post) {
    return client._client.post({
      url: "/permission/{requestID}/reply",
      path: { requestID },
      body: { reply },
      throwOnError: true,
    })
  }
  return client.postSessionIdPermissionsPermissionId({
    path: { id: sessionID, permissionID: requestID },
    body: { response: reply },
    throwOnError: true,
  })
}

function runAegis(aegisRoot, payload) {
  return new Promise((resolveRun) => {
    const child = spawn(resolve(aegisRoot, "orchestrator.sh"), [], {
      env: { ...process.env, AEGIS_HOST_RUNTIME: "opencode" },
      stdio: ["pipe", "pipe", "pipe"],
    })
    let stdout = ""
    let stderr = ""
    child.stdout.setEncoding("utf8")
    child.stderr.setEncoding("utf8")
    child.stdout.on("data", (chunk) => { stdout += chunk })
    child.stderr.on("data", (chunk) => { stderr += chunk })
    child.on("error", (error) => resolveRun({ status: 1, stdout: "", stderr: error.message }))
    child.on("close", (status) => resolveRun({ status, stdout, stderr }))
    child.stdin.end(`${JSON.stringify(payload)}\n`)
  })
}

function ensureAskPermission(cfg, key) {
  if (!cfg.permission || typeof cfg.permission !== "object") {
    cfg.permission = {}
  }
  const current = cfg.permission[key]
  if (current && typeof current === "object") {
    const rules = { "*": "ask" }
    for (const [pattern, decision] of Object.entries(current)) {
      rules[pattern] = decision === "allow" ? "ask" : decision
    }
    cfg.permission[key] = rules
    return
  }
  if (current === undefined || current === "allow") {
    cfg.permission[key] = "ask"
  }
}

const AegisPlugin = async ({ directory, client } = {}, options = {}) => {
  const aegisRoot = options.aegisRoot ?? process.env.AEGIS_ROOT ?? defaultAegisRoot()
  const runner = options.runner ?? runAegis
  const argsByCall = new Map()

  return {
    config: (cfg) => {
      ensureAskPermission(cfg, "bash")
      ensureAskPermission(cfg, "edit")
      ensureAskPermission(cfg, "write")
    },
    "tool.execute.before": async (input, output) => {
      argsByCall.set(cacheKey(input), output?.args ?? {})
    },
    "tool.execute.after": async (input) => {
      argsByCall.delete(cacheKey(input))
    },
    event: async ({ event }) => {
      if (event?.type !== "permission.asked") return
      const input = event.properties
      if (!input || typeof input !== "object" || handledPermissions.has(input)) return
      handledPermissions.add(input)

      const payload = buildHookPayload(input, argsByCall.get(cacheKey(input)), directory, aegisRoot)
      try {
        const decision = parseAegisDecision(await runner(aegisRoot, payload))
        if (decision.decision === "ask" || !client) return
        await replyPermission(client, input.id, input.sessionID, decision.decision === "allow" ? "once" : "reject")
      } catch {}
    },
  }
}

Object.assign(AegisPlugin, {
  buildHookPayload,
  normalizeToolInput,
  normalizeToolName,
  parseAegisDecision,
  replyPermission,
})
export default AegisPlugin
