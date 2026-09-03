// SPDX-FileCopyrightText: 2026 qoo
// SPDX-License-Identifier: MIT
//
// Compares the block-cache path (`extract(entry:)`) with the streaming path
// (`readData(entry:)`) on a real archive: wall time and physical memory footprint.
//
//   sevenzip-bench <archive.7z> [scenario ...]
//
// scenarios: seq-extract seq-stream mid-extract mid-stream jump-stream (default: all)

import Darwin
import Foundation
import SevenZip

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
}

func measure(_ label: String, _ body: () throws -> Int) rethrows {
    let before = footprintMB()
    let start = Date()
    let bytes = try body()
    let seconds = Date().timeIntervalSince(start)
    let after = footprintMB()
    let mb = Double(bytes) / 1_048_576
    print(String(format: "%-14@ %8.1f MB in %6.3f s = %6.0f MB/s   footprint %6.0f -> %6.0f MB", label, mb, seconds, seconds > 0 ? mb / seconds : 0, before, after))
}

let args = CommandLine.arguments.dropFirst()
guard let path = args.first else {
    print("usage: sevenzip-bench <archive.7z> [scenario ...]")
    exit(2)
}
let scenarios = args.count > 1 ? Array(args.dropFirst()) : ["seq-extract", "seq-stream", "mid-extract", "mid-stream", "jump-stream"]

for scenario in scenarios {
    let archive = try Archive(fileURL: URL(fileURLWithPath: path))
    let entries = archive.entries.filter { !$0.directory && $0.uncompressedSize > 0 }
    let mid = entries[entries.count / 2]
    switch scenario {
    case "seq-extract":
        try measure(scenario) { try entries.reduce(0) { $0 + (try archive.extract(entry: $1)).count } }
    case "seq-stream":
        try measure(scenario) { try entries.reduce(0) { $0 + (try archive.readData(entry: $1)).count } }
    case "mid-extract":
        try measure(scenario) { try archive.extract(entry: mid).count }
    case "mid-stream":
        try measure(scenario) { try archive.readData(entry: mid).count }
    case "jump-stream":
        // middle page, then the one before it (restarts the block), then the one after (resumes)
        let i = entries.count / 2
        try measure("mid") { try archive.readData(entry: entries[i]).count }
        try measure("  previous") { try archive.readData(entry: entries[i - 1]).count }
        try measure("  next") { try archive.readData(entry: entries[i + 1]).count }
    default:
        print("unknown scenario \(scenario)")
    }
}
