.pragma library
var client = null;

function externalSet(path) {
    for (const name of Object.keys(client.states)) client.states[name].path = path;
    client.eventReceived("state", {});
}
