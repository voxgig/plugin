(ns run
  "The whole suite: pure sections by direct call, driver sections by
  command list, and a coverage guard above both.

  A plain runner rather than clojure.test, for the same reason the port has
  no `deps.edn` `:deps` map: a conformance suite whose only job is to run
  one corpus and report which entries disagree does not need a framework,
  and `clojure.test`'s reporting is built for assertions rather than for
  539 rows each naming itself."
  (:require [voxgig.plugin :as p]
            [voxgig.plugin.types :as t]
            [voxgig.plugin.capability :as cap]
            [voxgig.plugin.corpus :as corpus]
            [voxgig.plugin.driver :as driver]
            [voxgig.plugin.graph :as graph]
            [voxgig.plugin.ref :as r]
            [voxgig.plugin.resolve :as res]
            [voxgig.plugin.version :as v]
            [clojure.string :as str]))

(def pure-sections ["ref" "env" "version" "capability" "graph" "resolve" "config"])
(def driver-sections ["lifecycle" "order" "point" "export" "depend"
                      "declare" "state" "resource" "nest" "trace" "apply" "error"])

(defn- arg-at [e i] (get (or (t/get e "args") []) i))
(defn- in-of [e] (t/get e "in"))

(defn- subjects []
  (let [env #(p/apply-env (in-of %))
        rng #(v/parse-range (in-of %))
        capability #(cap/resolve-capability (t/get (in-of %) "req")
                                            (t/get (in-of %) "candidates"))
        gr #(graph/resolve-graph (in-of %))
        drive #(driver/drive (t/get % "cmd"))]
    (concat
     [["ref" {"parse" #(p/parse-ref (in-of %))
              "parsebad" #(p/parse-ref (in-of %))
              "format" #(p/format-ref (arg-at % 0) (arg-at % 1))
              "formatbad" #(p/format-ref (arg-at % 0) (arg-at % 1))
              "canon" #(r/canon-ref (in-of %))
              "name" #(p/check-name (in-of %))
              "tag" #(p/check-tag (in-of %))
              "bound" #(p/check-name (in-of %))
              "boundtag" #(p/check-tag (in-of %))}]
      ["env" {"option" env "value" env "toggle" env
              "profile" env "ambiguous" env "reserved" env}]
      ["version" {"range" rng "rangebad" rng
                  "satisfies" #(v/satisfies-range? (t/get (in-of %) "version")
                                                   (t/get (in-of %) "range"))}]
      ["capability" {"match" capability "nested" capability "rank" capability}]
      ["graph" {"resolve" gr "blocked" gr}]
      ["resolve" {"candidates" #(res/resolve-candidates (t/get (in-of %) "name")
                                                        (t/get (in-of %) "sources"))
                  "from" #(res/resolve-from (in-of %))}]
      ;; `config` picks its subject by group PREFIX rather than by name,
      ;; because the two functions split the section cleanly.
      ["config" (fn [group]
                  (cond
                    (str/starts-with? group "norm") #(p/normalize-config (in-of %))
                    (str/starts-with? group "opt") #(p/resolve-options (in-of %))
                    :else nil))]]
     (for [nm driver-sections] [nm (fn [_group] drive)]))))

(defn- subject-for [subjects group]
  (if (map? subjects) (t/get subjects group) (subjects group)))

;; Dispatch every group, and fail on a group the runner does not know - a
;; group silently not run is worse than a failure.
(defn- run-section [spec nm subjects state]
  (reduce
   (fn [state group]
     (if-let [f (subject-for subjects group)]
       (reduce (fn [state [i entry]]
                 (let [why (corpus/check entry f)]
                   (cond-> (update state :entries inc)
                     why (update :failures conj
                                 (str nm "/" (corpus/label group i entry) ": " why)))))
               state
               (map-indexed vector ((corpus/section spec nm) group)))
       (update state :failures conj (str nm ": corpus group with no subject: " group))))
   state
   (sort (keys (corpus/section spec nm)))))

;; EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails on a
;; GROUP with no subject; this closes the level above, because a whole
;; SECTION the runner never mentions is a section silently not run.
(defn- coverage [spec entries]
  (let [primary (or (t/get spec "primary") {})
        ran (set (concat pure-sections driver-sections))
        missing (sort (remove ran (keys primary)))
        extra (sort (remove #(contains? primary %) ran))]
    (cond-> []
      ;; The corpus metadata block is what turns on strict entry validation
      ;; in every runner, so a corpus that lost it must not silently
      ;; downgrade this port's checking.
      (not= 1 (t/get (or (t/get spec "PLUGIN") {}) "version"))
      (conj "corpus PLUGIN.version must be 1")

      (seq missing) (conj (str "corpus sections no test runs: " (str/join ", " missing)))
      (seq extra) (conj (str "tests name sections the corpus does not have: "
                             (str/join ", " extra)))
      ;; A floor, not a fixture: the corpus grows, and a run that suddenly
      ;; covers a fraction of it is the failure worth catching.
      (< entries 400) (conj (str "only " entries " corpus entries reachable")))))

(defn -main [& _]
  (let [spec (corpus/corpus)
        all (subjects)
        state (reduce (fn [state [nm subs]] (run-section spec nm subs state))
                      {:failures [] :entries 0}
                      all)
        failures (concat (:failures state) (coverage spec (:entries state)))]
    (if (empty? failures)
      (do (println (str "clojure: " (:entries state) " corpus entries across "
                        (count all) " sections, all pass"))
          (System/exit 0))
      (do (doseq [f failures] (binding [*out* *err*] (println f)))
          (binding [*out* *err*]
            (println (str "\nclojure: " (count failures) " failure(s) of "
                          (:entries state) " entries")))
          (System/exit 1)))))

(-main)
