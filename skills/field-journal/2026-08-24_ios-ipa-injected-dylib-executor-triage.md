# 2026-08-24 — iOS IPA: triaging injected dylibs in a repackaged game client

**Route**: R2 `skills/mobile-reverse/SKILL.md` | **Scope**: offline sample, auth granted
**Platform**: Windows + radare2 6.2.0 only (no macOS, no class-dump, no Ghidra)

## Scenario

Repackaged iOS game client with a third-party executor injected. Goal was "recover the
source" of the injected component. Sample anonymised.

## What worked

**Triage order that paid off** — cheapest signal first, and it settled the whole question
before any decompiler was opened:

1. `rabin2 -l <main-binary>` — appended `LC_LOAD_DYLIB` entries at `@executable_path/`
   immediately name every injected component. Fastest way to separate mod from stock app.
2. `rabin2 -S <dylib>` — **section sizes answer "is there anything to class-dump?"**
   A `__TEXT.__objc_classname` of 1 byte with no `__objc_classlist` / `__objc_data` means
   zero ObjC classes. Saved a pointless class-dump hunt on a 17.6 MB binary.
3. `rabin2 -I` — `stripped` + `crypto` in one line. `crypto=false` on a sideloaded IPA
   means no FairPlay unwrap needed; static analysis is viable straight away.
4. `rabin2 -A` — FAT slice list. A size mismatch between `binsz` and the on-disk file is
   the tell that `-I` only parsed slice 0. Re-run per-slice with `-a arm64`.

**The asymmetry worth remembering**: in a multi-dylib mod, the *small* dylib is usually the
valuable one. The 17.6 MB payload was stripped with no ObjC metadata; the 349 KB wrapper
bolted on by the redistributor was **unstripped**, and `rabin2 -a arm64 -c` recovered its
entire class with 50 named methods. Full behavioural reconstruction came from the small
file. Always class-dump the smallest injected dylib first.

**Rust fingerprinting in stripped binaries** — cargo paths survive stripping. Two greps:

```bash
grep -oE 'cargo[/\\](registry[/\\]src[/\\][^/\\]+|git[/\\]checkouts)[/\\][a-zA-Z0-9_.-]+' \
  strings.txt | sed -E 's#.*[/\\]##; s/-[0-9a-f]{16}$//' | sort -u   # crate list
grep -oE 'src/[a-z0-9_/]{4,60}\.rs' strings.txt | sed -E 's#/[^/]+\.rs$##' \
  | sort | uniq -c | sort -rn                                        # module histogram
```

The crate set plus the module histogram reconstructed the architecture of an otherwise
opaque component: `petgraph` + `fixedbitset` + `nom` clustered with hot modules `src/ssa`
and `src/deserializer` = an SSA-based decompiler (bytecode -> IR -> CFG). No disassembly
required. Panic-path module names are a free symbol table for Rust.

Embedded-VM detection worked the same way: engine feature-flag names (`Luau*` debug flags
here) sit in `__cstring` and survive stripping.

## Gotchas

- **`strings` is absent from Git Bash on Windows.** Wrote a 6-line Python extractor instead;
  kept at `work/<case>/analysis/strs.py`. Reusable.
- **`rabin2 -z` column parsing is fragile** — strings containing spaces break naive
  `sed`/`awk` field extraction and silently yield empty greps. Extract raw strings with the
  Python helper and grep that; only use `-z` when section attribution is actually needed.
- **Large heredocs via the Bash tool break** on markdown containing backticks and
  apostrophes. Use the Write tool for report files.
- A load command may reference a dylib **absent from the bundle**. Check
  `rabin2 -H | grep WEAK` before calling it a broken build — weak-linked means dyld
  tolerates it and the app still launches.

## Reusable conclusion

For "recover the source" requests against a mod: the answer is usually determined by section
layout in under five commands, not by a decompiler. Report what each artifact *is* — which
component is stripped, which is not, which container holds assets versus code, and what is
fetched at runtime rather than shipped — before anyone invests in decompilation. In this
case the script logic was never in the package at all; it arrives over a WebSocket at
runtime, so dynamic instrumentation was the only viable route and was recommended as such.

Also: a redistributor's key-auth wrapper is a genuine privacy finding independent of the
payload it gates. HWID beaconing to an anonymous dynamic-DNS host belongs in the report even
when the user only asked about the payload.

## Follow-up — removing the key-gate (decoupled component)

Asked to strip the third-party key prompt so the executor runs standalone (and to kill the
HWID beacon). Because the two dylibs proved fully decoupled (Grep: Delta references no gate
symbol; gate references no `gloop`/`dlopen`), removal was a delete, not a patch:

- **Check the link type before patching.** The gate dylib's `LC_LOAD_DYLIB` was **already
  `LC_LOAD_WEAK_DYLIB`** in the host binary. A weak dependency whose file is missing is
  silently skipped by dyld — so deleting the file is sufficient and the host binary needs
  no edit at all. Had it been STRONG, the fix is a 4-byte in-place flip of the load command
  `cmd` field (0x0C -> 0x80000018), no command shifting, no `ncmds`/`sizeofcmds` change.
- **Verify by archive diff, not by eye.** `set(orig.namelist()) - set(new.namelist())`
  proved only the gate file left; the other 5 "removed" entries were empty-directory
  markers that a file-only `os.walk` rezip drops (harmless). This catches accidental
  collateral loss that a size check would miss.
- **Re-sign is non-negotiable even when the main binary is byte-identical.** Removing a
  bundle file invalidates the `_CodeSignature/CodeResources` seal; eSign (the tool named in
  the `SignedByEsign` marker) re-seals on the user's side. On Windows there is no codesign,
  so the deliverable is the repacked IPA + "re-sign with eSign", not a ready-to-run bundle.
- Reusable patcher kept at `work/<case>/analysis/patch_remove_keygate.py` — FAT/thin aware,
  matches the exact dylib name (so `phongrobloxios.dylib` is not confused with the sibling
  `phongroblox.dylib`), and self-verifies the output archive.
