.pragma library

function targets(statuses, output, project) {
    return Object.keys(statuses || {}).filter(name => {
        const state = statuses[name];
        return (output === "*" || output === name) && typeof state?.path === "string"
            && (!project || state.path === project);
    });
}

function optionsFor(statuses, output) {
    const names = targets(statuses, output || "*", "");
    const defaults = { fps: 60, scaling: "fill", volume: 0, mute: false, transition: "fade", duration: 300, color: "#000000" };
    const result = Object.assign({}, defaults, names.length ? statuses[names[0]].options || {} : {});
    result.mixed = {};
    result.count = names.length;
    for (const key of Object.keys(defaults)) {
        result.mixed[key] = names.some(name => (statuses[name].options?.[key] ?? defaults[key]) !== result[key]);
    }
    return result;
}

function optionRequests(statuses, output, changes) {
    return targets(statuses, output || "*", "").map(name => ({
        op: "set", output: name, path: statuses[name].path,
        options: Object.assign({}, statuses[name].options || {}, changes)
    }));
}

function propertyTargets(statuses, output, project) {
    return project ? targets(statuses, output || "*", project).filter(name =>
        !["loading", "error", "none"].includes(statuses[name].state)) : [];
}

function propertiesFor(cache, statuses, output, project) {
    const names = propertyTargets(statuses, output, project);
    if (!names.length) return [];
    return (cache[names[0]] || []).filter(p => p.visible !== false &&
        ["bool", "slider", "combo", "color", "textinput", "file", "directory", "scenetexture"].includes(p.type))
        .map(p => {
            const copy = Object.assign({}, p);
            copy.mixed = names.some(name => {
                const other = (cache[name] || []).find(item => item.name === p.name);
                return !other || JSON.stringify(other.value) !== JSON.stringify(p.value);
            });
            return copy;
        });
}

function propertyLabel(property) {
    const label = property.text || property.name;
    return label.startsWith("ui_browse_properties_") ? label.slice(21).replace(/_/g, " ") : label;
}

function libraryItems(items) {
    return (Array.isArray(items) ? items : []).filter(item => item.type === "scene" || item.type === "video")
        .map(item => ({ id: item.id, title: item.title, kind: item.type, source: "workshop",
            tags: item.tags || [], rating: item.rating || "", path: item.path,
            preview: !item.preview ? "" : item.preview.startsWith("/") ? item.preview : `${item.path}/${item.preview}` }));
}
