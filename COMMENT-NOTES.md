# Implementation rationale

Host transitions are sequential and reconciliation reaches a fixed point eagerly. Reentrant lifecycle transitions are rejected. These properties allow the same lifecycle semantics in runtimes with different concurrency mechanisms.

Capability providers are ranked by descending version, ascending priority, then declaration position. Point-binding order bands do not rank capabilities: a provider may have several bindings or no bindings.

Rust drops RefCell borrows before invoking callbacks. Holding a borrow over plugin code can turn a lifecycle operation into a panic.

Sources: [host](typescript/src/Host.ts), [capability resolution](go/plugin/capability.go), [Rust guide](rust/AGENTS.md).

Corpus shape validation is separate from JSON generation so optional empty containers retain their assertion meaning. The runner checks cross-field relationships and nonempty test groups. Artifact validation checks that the corpus version marker exists; unification alone can fill an absent marker.
