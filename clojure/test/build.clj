(ns build
  "`make build`, and not a no-op.

  Clojure is late-bound: a typo in a branch no test happens to take is a
  runtime error, not a compile error, so \"it loaded\" is the only
  compile-time claim available - and it is worth making, because loading a
  namespace DOES macroexpand and compile every form in it to bytecode.

  Reflection warnings are FAILURES here. A reflective call is a call whose
  target was never checked, and this port makes several java calls
  (`String.indexOf`, `StringBuilder`, `Integer/parseInt`) where a wrong
  hint would silently cost a lookup per character of every corpus
  document.")

(def namespaces
  '[voxgig.plugin.types voxgig.plugin.json voxgig.plugin.ref voxgig.plugin.version
    voxgig.plugin.capability voxgig.plugin.resolve voxgig.plugin.export
    voxgig.plugin.order voxgig.plugin.point voxgig.plugin.config voxgig.plugin.env
    voxgig.plugin.graph voxgig.plugin.catalog voxgig.plugin.host voxgig.plugin
    voxgig.plugin.corpus voxgig.plugin.driver])

(let [noise (java.io.StringWriter.)]
  (binding [*warn-on-reflection* true *err* noise *out* noise]
    (doseq [n namespaces] (require n :reload)))
  (let [text (str noise)]
    (if (empty? text)
      (println (str "clojure: " (count namespaces) " namespaces compile"))
      (do (binding [*out* *err*] (print text) (flush))
          (System/exit 1)))))
