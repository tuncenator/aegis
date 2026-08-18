import test from "node:test"
import assert from "node:assert/strict"

import AegisPlugin from "../../.opencode/plugins/aegis.js"

const { buildHookPayload, parseAegisDecision } = AegisPlugin

test("buildHookPayload maps OpenCode bash input to Claude hook shape", () => {
  const payload = buildHookPayload(
    { type: "bash", sessionID: "s1", callID: "c1" },
    { command: "git status" },
    "/repo",
    "/aegis",
  )

  assert.deepEqual(payload, {
    session_id: "s1",
    cwd: "/repo",
    tool_name: "Bash",
    tool_input: { command: "git status" },
  })
})

test("parseAegisDecision maps hard deny exit to deny", () => {
  assert.deepEqual(parseAegisDecision({ status: 2, stdout: "" }), {
    decision: "deny",
    reason: "aegis hard deny",
  })
})

test("parseAegisDecision never allows output from a failed process", () => {
  assert.deepEqual(parseAegisDecision({
    status: 1,
    stdout: '{"hookSpecificOutput":{"permissionDecision":"allow"}}',
    stderr: "classifier failed",
  }), {
    decision: "ask",
    reason: "classifier failed",
  })
})

test("permission.asked event replies once for Aegis allow", async () => {
  const replies = []
  const plugin = await AegisPlugin(
    {
      directory: "/repo",
      client: { permission: { reply: async (reply) => replies.push(reply) } },
    },
    {
      aegisRoot: "/aegis",
      runner: (_root, payload) => {
        assert.equal(payload.tool_name, "Bash")
        assert.deepEqual(payload.tool_input, { command: "ls" })
        return {
          status: 0,
          stdout: '{"hookSpecificOutput":{"permissionDecision":"allow"}}',
        }
      },
    },
  )
  const toolInput = { tool: "bash", sessionID: "s", callID: "c" }
  const toolOutput = { args: { command: "ls" } }

  await plugin["tool.execute.before"](toolInput, toolOutput)
  await plugin.event({ event: permissionEvent("allow", "s", "c") })

  assert.deepEqual(replies, [{
    requestID: "allow",
    reply: "once",
  }])
})

test("permission.asked event uses canonical OpenCode metadata", async () => {
  const replies = []
  const plugin = await AegisPlugin(
    {
      directory: "/repo",
      client: { permission: { reply: async (reply) => replies.push(reply) } },
    },
    {
      aegisRoot: "/aegis",
      runner: (_root, payload) => {
        assert.equal(payload.tool_name, "Bash")
        assert.deepEqual(payload.tool_input, { command: "ls" })
        return {
          status: 0,
          stdout: '{"hookSpecificOutput":{"permissionDecision":"allow"}}',
        }
      },
    },
  )
  await plugin.event({ event: permissionEvent("p1", "s", "c") })

  assert.equal(replies[0].reply, "once")
})

test("permission.asked handles a request only once when the plugin is loaded twice", async () => {
  let runs = 0
  const runner = () => {
    runs += 1
    return { status: 0, stdout: '{"hookSpecificOutput":{"permissionDecision":"allow"}}' }
  }
  const client = { permission: { reply: async () => {} } }
  const first = await AegisPlugin({ directory: "/repo", client }, { aegisRoot: "/aegis", runner })
  const second = await AegisPlugin({ directory: "/repo", client }, { aegisRoot: "/aegis", runner })
  const event = permissionEvent("duplicate", "s", "c")

  await first.event({ event })
  await second.event({ event })

  assert.equal(runs, 1)
})

test("permission.asked leaves Aegis ask pending for the user", async () => {
  let replies = 0
  const plugin = await AegisPlugin(
    {
      directory: "/repo",
      client: { permission: { reply: async () => { replies += 1 } } },
    },
    { aegisRoot: "/aegis", runner: () => ({ status: 0, stdout: "" }) },
  )

  await plugin.event({ event: permissionEvent("ask", "s", "c") })

  assert.equal(replies, 0)
})

function permissionEvent(id, sessionID, callID) {
  return {
    type: "permission.asked",
    properties: {
      id,
      sessionID,
      permission: "bash",
      patterns: ["ls"],
      metadata: { command: "ls" },
      always: [],
      tool: { messageID: "m", callID },
    },
  }
}

test("config hook asks for bash edit and write without replacing deny", async () => {
  const plugin = await AegisPlugin({ directory: "/repo" }, { aegisRoot: "/aegis" })
  const cfg = { permission: { bash: "allow", edit: "deny" } }

  plugin.config(cfg)

  assert.deepEqual(cfg.permission, { bash: "ask", edit: "deny", write: "ask" })
})

test("config hook rewrites granular allows without overriding denies", async () => {
  const plugin = await AegisPlugin({ directory: "/repo" }, { aegisRoot: "/aegis" })
  const cfg = { permission: { bash: { "git status": "allow", "rm *": "deny" } } }

  plugin.config(cfg)

  assert.deepEqual(cfg.permission.bash, { "*": "ask", "git status": "ask", "rm *": "deny" })
  assert.equal(Object.entries(cfg.permission.bash).findLast(([pattern]) => pattern === "*" || pattern === "rm *")[1], "deny")
})
