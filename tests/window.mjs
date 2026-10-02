// Extract and execute the production geometry/focus rules, without UI access.
import { readFileSync, writeFileSync } from 'node:fs';
const source = readFileSync('lua/draft/window.swift', 'utf8');
const rules = source.split('// BEGIN pure workspace rules')[1].split('\n').slice(1).join('\n').split('// END pure workspace rules.')[0];
const tests = String.raw`
for workspace in [NSRect(x: 0, y: 30, width: 1440, height: 870), NSRect(x: -1920, y: -600, width: 1920, height: 1080)] {
    var divider = workspace.minX + workspace.width * 0.55
    for i in 0..<1000 {
        let frames = splitFrames(at: divider, in: workspace)
        assert(abs(frames.preview.minX - frames.terminal.maxX - 2) < 0.001)
        assert(frames.terminal.minX == workspace.minX && frames.preview.maxX == workspace.maxX)
        assert(frames.terminal.minY == workspace.minY && frames.preview.height == workspace.height)
        assert(frames.terminal.width >= workspace.width * 0.40 - 0.001)
        assert(frames.preview.width >= workspace.width * 0.20 - 0.001)
        let repeatFrames = splitFrames(at: frames.terminal.maxX, in: workspace)
        assert(repeatFrames.terminal == frames.terminal && repeatFrames.preview == frames.preview)
        divider = workspace.minX + CGFloat((i * 137) % 2400) - 200
    }
}
for _ in 0..<10 {
    assert(pairedForeground(frontmost: 100, terminal: 100, draft: 200, exactTerminalFocused: true))
    assert(!pairedForeground(frontmost: 300, terminal: 100, draft: 200, exactTerminalFocused: true))
    assert(!pairedForeground(frontmost: 100, terminal: 100, draft: 200, exactTerminalFocused: false))
    assert(pairedForeground(frontmost: 200, terminal: 100, draft: 200, exactTerminalFocused: false))
}
assert(!pairedForeground(frontmost: nil, terminal: 100, draft: 200, exactTerminalFocused: true))
print("Draft: 2,000 split geometry checks and exact-window foreground rules passed (no GUI coverage)")
`;
writeFileSync(process.argv[2] || '/tmp/draft-window-check.swift', 'import AppKit\n' + rules + tests);
