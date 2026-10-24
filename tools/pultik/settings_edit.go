package main

// In-place edit of Claude's settings.json. The installer owns two SessionStart
// hook groups and nothing else in that file, so it rewrites only the
// hooks.SessionStart array and leaves every other byte as the user wrote it:
// key order, indentation, and the `&&`, `<` and `>` in their commands. A
// decode-and-marshal round trip would sort every key, escape & < > as &
// and friends, and turn a one-line diff into a whole-file one.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
)

type byteSpan struct{ start, end int }

type jsonMember struct {
	key   string
	whole byteSpan // from the key's opening quote to the end of the value
	value byteSpan
	colon string // the bytes between the key and its value, e.g. ": "
}

// jsonStyle is how a file lays out its containers, read from the root object
// so inserted text matches the rest of the file.
type jsonStyle struct {
	multiline bool
	unit      string // one indent level
	itemSep   string // between items of a one-line container
	colon     string
	newline   string // "\r\n" in a CRLF file, so inserted lines match
}

// jsonLayout is where one container puts its children.
type jsonLayout struct {
	multiline   bool
	childIndent string
	closeIndent string
	itemSep     string
	newline     string
}

// editSessionStart returns raw with hooks.SessionStart holding every group it
// held before minus pultik's hooks, plus ours. raw must be a valid JSON object
// whose hooks and hooks.SessionStart, when present, are an object and an array.
func editSessionStart(raw []byte, ours []hookGroup) ([]byte, error) {
	rootStart := skipJSONSpace(raw, 0)
	root := byteSpan{rootStart, jsonValueEnd(raw, rootStart)}
	rootMembers := jsonObjectMembers(raw, root)
	style := documentStyle(raw, root, rootMembers)

	hooks, found := lastJSONMember(rootMembers, "hooks")
	if !found {
		value := map[string]any{"SessionStart": ours}
		return insertJSONMember(raw, root, rootMembers, "hooks", value, style)
	}
	if isJSONNull(raw, hooks.value) {
		return replaceJSONValue(raw, hooks, map[string]any{"SessionStart": ours}, style)
	}
	hookMembers := jsonObjectMembers(raw, hooks.value)
	sessionStart, found := lastJSONMember(hookMembers, "SessionStart")
	if !found {
		return insertJSONMember(raw, hooks.value, hookMembers, "SessionStart", ours, style)
	}
	if isJSONNull(raw, sessionStart.value) {
		return replaceJSONValue(raw, sessionStart, ours, style)
	}

	array := sessionStart.value
	elements := jsonArrayElements(raw, array)
	layout := containerLayout(raw, array, elements, style)
	var items []string
	for _, element := range elements {
		text, keep := withoutPultikHooksText(raw, element, style)
		if keep {
			items = append(items, text)
		}
	}
	for _, group := range ours {
		text, err := renderJSON(group, layout.childIndent, style, layout.multiline)
		if err != nil {
			return nil, err
		}
		items = append(items, text)
	}
	edited := splice(raw, array, renderJSONArray(items, layout))
	if sameJSON(raw, edited) {
		return raw, nil
	}
	return edited, nil
}

// withoutPultikHooksText is withoutPultikHooks on the group's own bytes: a
// group with none of our hooks comes back verbatim, a group of only ours is
// dropped, and a mixed group loses just our entries from its hooks array.
func withoutPultikHooksText(raw []byte, group byteSpan, style jsonStyle) (string, bool) {
	text := string(raw[group.start:group.end])
	if raw[group.start] != '{' {
		return text, true
	}
	hooks, found := lastJSONMember(jsonObjectMembers(raw, group), "hooks")
	if !found || raw[hooks.value.start] != '[' {
		return text, true
	}
	entries := jsonArrayElements(raw, hooks.value)
	var kept []string
	for _, entry := range entries {
		var hook any
		if err := json.Unmarshal(raw[entry.start:entry.end], &hook); err == nil && isPultikHook(hook) {
			continue
		}
		kept = append(kept, string(raw[entry.start:entry.end]))
	}
	switch {
	case len(kept) == len(entries):
		return text, true
	case len(kept) == 0:
		return "", false
	}
	layout := containerLayout(raw, hooks.value, entries, style)
	return string(raw[group.start:hooks.value.start]) +
		renderJSONArray(kept, layout) +
		string(raw[hooks.value.end:group.end]), true
}

func insertJSONMember(raw []byte, object byteSpan, members []jsonMember, key string, value any, style jsonStyle) ([]byte, error) {
	children := make([]byteSpan, len(members))
	for i, member := range members {
		children[i] = member.whole
	}
	layout := containerLayout(raw, object, children, style)
	keyText, err := renderJSON(key, "", style, false)
	if err != nil {
		return nil, err
	}
	valueText, err := renderJSON(value, layout.childIndent, style, layout.multiline)
	if err != nil {
		return nil, err
	}
	member := keyText + style.colon + valueText
	if len(members) == 0 {
		inner := byteSpan{object.start + 1, object.end - 1}
		if layout.multiline {
			return splice(raw, inner, layout.newline+layout.childIndent+member+layout.newline+layout.closeIndent), nil
		}
		return splice(raw, inner, member), nil
	}
	end := members[len(members)-1].whole.end
	separator := layout.itemSep
	if layout.multiline {
		separator = "," + layout.newline + layout.childIndent
	}
	return splice(raw, byteSpan{end, end}, separator+member), nil
}

// replaceJSONValue swaps a member's null for value; json.Unmarshal reads a
// null the same as a missing key.
func replaceJSONValue(raw []byte, member jsonMember, value any, style jsonStyle) ([]byte, error) {
	text, err := renderJSON(value, lineIndent(raw, member.whole.start), style, style.multiline)
	if err != nil {
		return nil, err
	}
	return splice(raw, member.value, text), nil
}

func isJSONNull(raw []byte, value byteSpan) bool {
	return string(raw[value.start:value.end]) == "null"
}

func renderJSONArray(items []string, layout jsonLayout) string {
	if len(items) == 0 {
		return "[]"
	}
	if !layout.multiline {
		return "[" + strings.Join(items, layout.itemSep) + "]"
	}
	return "[" + layout.newline + layout.childIndent +
		strings.Join(items, ","+layout.newline+layout.childIndent) +
		layout.newline + layout.closeIndent + "]"
}

// renderJSON encodes v without HTML escaping. Multi-line output starts at the
// current column, indents its later lines from prefix, and ends its lines the
// way the file does.
func renderJSON(v any, prefix string, style jsonStyle, multiline bool) (string, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if multiline {
		encoder.SetIndent(prefix, style.unit)
	}
	if err := encoder.Encode(v); err != nil {
		return "", err
	}
	text := strings.TrimSuffix(buffer.String(), "\n")
	return strings.ReplaceAll(text, "\n", style.newline), nil
}

func documentStyle(raw []byte, root byteSpan, members []jsonMember) jsonStyle {
	style := jsonStyle{multiline: true, unit: "  ", itemSep: ",", colon: ": ", newline: "\n"}
	if bytes.Contains(raw, []byte("\r\n")) {
		style.newline = "\r\n"
	}
	if len(members) == 0 {
		return style
	}
	first := members[0]
	style.colon = first.colon
	style.multiline = bytes.ContainsRune(raw[root.start+1:first.whole.start], '\n')
	if style.multiline {
		if unit := strings.TrimPrefix(lineIndent(raw, first.whole.start), lineIndent(raw, root.start)); unit != "" {
			style.unit = unit
		}
	} else if len(members) > 1 {
		style.itemSep = string(raw[first.whole.end:members[1].whole.start])
	}
	return style
}

func containerLayout(raw []byte, container byteSpan, children []byteSpan, style jsonStyle) jsonLayout {
	open := lineIndent(raw, container.start)
	layout := jsonLayout{
		multiline:   style.multiline,
		childIndent: open + style.unit,
		closeIndent: open,
		itemSep:     style.itemSep,
		newline:     style.newline,
	}
	if len(children) == 0 {
		return layout
	}
	first, last := children[0], children[len(children)-1]
	layout.multiline = bytes.ContainsRune(raw[container.start+1:first.start], '\n')
	if layout.multiline {
		layout.childIndent = lineIndent(raw, first.start)
		if bytes.ContainsRune(raw[last.end:container.end-1], '\n') {
			layout.closeIndent = lineIndent(raw, container.end-1)
		}
	} else if len(children) > 1 {
		layout.itemSep = string(raw[first.end:children[1].start])
	}
	return layout
}

// lineIndent is the leading whitespace of the line holding offset.
func lineIndent(raw []byte, offset int) string {
	start := bytes.LastIndexByte(raw[:offset], '\n') + 1
	end := start
	for end < len(raw) && (raw[end] == ' ' || raw[end] == '\t') {
		end++
	}
	return string(raw[start:end])
}

func splice(raw []byte, span byteSpan, text string) []byte {
	out := make([]byte, 0, len(raw)-(span.end-span.start)+len(text))
	out = append(out, raw[:span.start]...)
	out = append(out, text...)
	return append(out, raw[span.end:]...)
}

func sameJSON(a, b []byte) bool {
	var left, right any
	if json.Unmarshal(a, &left) != nil || json.Unmarshal(b, &right) != nil {
		return false
	}
	return reflect.DeepEqual(left, right)
}

// The scanners below walk a document that json.Unmarshal already accepted, so
// they only find boundaries and never validate.

func skipJSONSpace(raw []byte, i int) int {
	for i < len(raw) && (raw[i] == ' ' || raw[i] == '\t' || raw[i] == '\n' || raw[i] == '\r') {
		i++
	}
	return i
}

func jsonStringEnd(raw []byte, start int) int {
	for i := start + 1; i < len(raw); i++ {
		switch raw[i] {
		case '\\':
			i++
		case '"':
			return i + 1
		}
	}
	return len(raw)
}

func jsonValueEnd(raw []byte, start int) int {
	switch raw[start] {
	case '"':
		return jsonStringEnd(raw, start)
	case '{', '[':
		depth := 0
		for i := start; i < len(raw); i++ {
			switch raw[i] {
			case '"':
				i = jsonStringEnd(raw, i) - 1
			case '{', '[':
				depth++
			case '}', ']':
				depth--
				if depth == 0 {
					return i + 1
				}
			}
		}
		return len(raw)
	}
	i := start
	for i < len(raw) && !strings.ContainsRune(" \t\r\n,]}", rune(raw[i])) {
		i++
	}
	return i
}

func jsonObjectMembers(raw []byte, object byteSpan) []jsonMember {
	var members []jsonMember
	i := skipJSONSpace(raw, object.start+1)
	for i < object.end && raw[i] == '"' {
		keyEnd := jsonStringEnd(raw, i)
		var key string
		_ = json.Unmarshal(raw[i:keyEnd], &key)
		colonEnd := skipJSONSpace(raw, skipJSONSpace(raw, keyEnd)+1)
		valueEnd := jsonValueEnd(raw, colonEnd)
		members = append(members, jsonMember{
			key:   key,
			whole: byteSpan{i, valueEnd},
			value: byteSpan{colonEnd, valueEnd},
			colon: string(raw[keyEnd:colonEnd]),
		})
		i = skipJSONSpace(raw, valueEnd)
		if i < object.end && raw[i] == ',' {
			i = skipJSONSpace(raw, i+1)
		}
	}
	return members
}

func jsonArrayElements(raw []byte, array byteSpan) []byteSpan {
	var elements []byteSpan
	i := skipJSONSpace(raw, array.start+1)
	for i < array.end-1 {
		end := jsonValueEnd(raw, i)
		elements = append(elements, byteSpan{i, end})
		i = skipJSONSpace(raw, end)
		if i < array.end && raw[i] == ',' {
			i = skipJSONSpace(raw, i+1)
		}
	}
	return elements
}

// lastJSONMember mirrors json.Unmarshal, where a repeated key's last value wins.
func lastJSONMember(members []jsonMember, key string) (jsonMember, bool) {
	for i := len(members) - 1; i >= 0; i-- {
		if members[i].key == key {
			return members[i], true
		}
	}
	return jsonMember{}, false
}

func checkSettingsShape(raw []byte) error {
	var settings map[string]any
	if err := json.Unmarshal(raw, &settings); err != nil {
		return fmt.Errorf("invalid JSON: %w", err)
	}
	if settings == nil {
		return fmt.Errorf("settings must be a JSON object")
	}
	if value := settings["hooks"]; value != nil {
		hooks, isObject := value.(map[string]any)
		if !isObject {
			return fmt.Errorf("hooks must be an object")
		}
		if value := hooks["SessionStart"]; value != nil {
			if _, isArray := value.([]any); !isArray {
				return fmt.Errorf("hooks.SessionStart must be an array")
			}
		}
	}
	return nil
}
