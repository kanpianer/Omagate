const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

// Service.qml cannot be imported by Node, but the endpoint validators it uses
// before invoking vpncmd are plain JavaScript. Extract and exercise them so a
// regression cannot silently reopen the path from the relay list to the client.
const source = fs.readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8")
const start = source.indexOf("  function isEndpointIp")
const end = source.indexOf("  readonly property string country:")
assert.ok(start >= 0 && end > start, "could not locate the endpoint validators in Service.qml")
const validators = new Function(
  source.slice(start, end) + "\nreturn { isEndpointIp, isEndpointPort, isEndpointNode }"
)()

for (const ip of [
  "8.8.8.8",
  "1.1.1.1",
  "255.255.255.255",
  "2001:4860:4860::8888",
  "1:2:3:4:5:6:7:8",
  "::1",
  " 8.8.8.8 "
]) {
  assert.equal(validators.isEndpointIp(ip), true, ip)
}

for (const ip of [
  "256.1.1.1",
  "1.2.3",
  "1:2:3:4:5:6:7:8:9",
  "1::2::3",
  "::::",
  "fe80::1%eth0",
  "evil;rm -rf /",
  "",
  null
]) {
  assert.equal(validators.isEndpointIp(ip), false, String(ip))
}

for (const port of ["443", "65535", " 443 "]) {
  assert.equal(validators.isEndpointPort(port), true, String(port))
}

for (const port of ["0", "65536", "-1", "abc", "", null]) {
  assert.equal(validators.isEndpointPort(port), false, String(port))
}

assert.equal(validators.isEndpointNode({ ip: "8.8.8.8", port: 443 }), true)
assert.equal(validators.isEndpointNode({ ip: "8.8.8.8", port: "443" }), true)
assert.equal(validators.isEndpointNode({ ip: "8.8.8.8", port: 0 }), false)
assert.equal(validators.isEndpointNode({ ip: "not-an-ip", port: 443 }), false)
assert.equal(validators.isEndpointNode(null), false)

console.log("service endpoint tests passed")
