(ns voxgig.plugin.driver
  "The driver (DOCS.md section 4).

  Every port implements this same small thing and nothing else is
  port-specific: the probe catalog, the command interpreter, and the
  canonical observable."
  (:require [voxgig.plugin :as p]
            [voxgig.plugin.types :as t]
            [voxgig.plugin.host :as h]))

;; A sentinel for "this command produced nothing", so a command that
;; legitimately produces nil - `export` of a missing key - still overwrites
;; the previous result.
(def ^:private nothing ::nothing)

;; EVERY BINDING IS ARITY TWO, `(next arg)`, hook and chain alike. `next`
;; is nil for a hook. One arity means `point/compose` and `point-emit` do
;; not have to know which kind of point they are holding - and the kind is
;; the HOST's property, not the binding's.

(defn- opt [i k] (t/get (h/inst-options i) k))
(defn- count-of [i] (or (t/get (h/inst-state i) "count") 0))
(defn- bump [i by] (h/state-put! i "count" (+ (count-of i) by)))

(defn- declare-provides [i]
  (doseq [prov (or (opt i "provides") [])] (h/provides! i prov)))

(defn- boom [i callback]
  (when (= callback (opt i "fail"))
    ;; `bare` raises WITHOUT a code - the ordinary library error section
    ;; 12's `plugin_<phase>_failed` codes exist to wrap.
    (if (t/truthy (opt i "bare"))
      (throw (RuntimeException. (str "probe failed at " callback)))
      (t/fail (or (opt i "code") (str "plugin_" callback "_failed"))
              (str "probe failed at " callback)))))

(defn- reenter [i callback]
  ;; A transition from inside a lifecycle callback (section 5.2).
  (when (= callback (opt i "reenter"))
    (h/activate (h/inst-host i) (h/inst-ref i))))

(defn base-points
  "The points every driver host declares. DOCS.md section 4.3 defines
  `probe` as binding one hook point (`p`) and wrapping one chain point
  (`c`), so a host without them cannot load the probe at all - they are
  part of the contract's baseline rather than a fixture convenience. `v` is
  the provider point the `provider` probe defaults to."
  []
  {"p" {"kind" "hook"}
   "c" {"kind" "chain" "base" identity}
   "v" {"kind" "provider"}})

(defn with-points
  "A `host` command REPLACES a base point rather than merging into it, so
  an entry can redeclare `c` with its own base or `v` as exclusive without
  inheriting the default's shape."
  ([] (with-points nil))
  ([extra] (merge (base-points) (or extra {}))))

(declare probes)

(defn- record [nm]
  {"name" nm
   "define" (fn [i] (bump i 0))
   "activate" (fn [i] (h/acquire! i))})

(defn- probe []
  {"name" "probe"
   "define"
   (fn [i]
     (bump i 0)
     (let [band (opt i "band")]
       ;; One hook binding (`p`) and one chain wrap (`c`) - the workhorse
       ;; shape DOCS.md section 4.3 specifies. `p` RETURNS NOTHING, as the
       ;; canonical's arrow-with-a-block does: in `bail` mode a return is
       ;; an answer, and a counter that answered with its own count would
       ;; make every hook that keeps one un-bailable.
       (h/bind! i "p" (fn [_next _arg] (bump i 1) nil) band)
       ;; Wrap AFTER next, so the result spells the nesting left to right:
       ;; outermost first. Wrapping the ARGUMENT instead would spell it
       ;; backwards and make every chain expectation read wrong.
       (h/bind! i "c" (fn [nxt v] (str (or (opt i "wrap") ":") (nxt v))) band))
     (h/export! i "client" (h/inst-ref i))
     ;; The instance api itself, so the driver's `stray` command can call
     ;; `release` from OUTSIDE a lifecycle callback.
     (h/export! i "inst" i)
     (declare-provides i))
   "activate"
   (fn [i]
     (h/acquire! i)
     ;; Section 6.5: an instance that is itself a host. The outer owns the
     ;; inner's lifetime - registered in the scope, so it closes on
     ;; deactivate in the same reverse unwind as every other resource.
     (when-let [nest (opt i "nest")]
       (let [inner (h/nest! i {"points" (with-points)})]
         (doseq [d (probes)] (h/catalog-add! inner d))
         (doseq [r nest] (h/ready inner r)))))})

(defn- noisy []
  {"name" "noisy"
   "define" (fn [i] (bump i 0) (boom i "define"))
   "activate" (fn [i]
                ;; Acquire BEFORE the raise, so a failing activate has
                ;; something to leak if the scope does not unwind - which
                ;; is the whole point of the entry that asserts open == 0
                ;; afterwards.
                (h/acquire! i)
                (reenter i "activate")
                (boom i "activate"))
   "deactivate" (fn [i] (boom i "deactivate"))
   "close" (fn [i] (boom i "close"))})

(defn- greedy []
  {"name" "greedy"
   "define"
   (fn [i]
     (h/state-put! i "count" 0)
     ;; Section 8.1 puts resource capture in `activate`. `early` NAMES the
     ;; call that reaches for it in `define`, because `acquire` and
     ;; `release` carry the guard separately.
     (when (= "acquire" (opt i "early")) (h/acquire! i))
     (when (= "release" (opt i "early")) (h/release! i (fn [] nil))))
   "activate"
   (fn [i]
     (let [handles (vec (repeatedly (or (opt i "acquire") 0) #(h/acquire! i)))]
       ;; Release some explicitly; the DIFFERENCE is what the instance
       ;; scope must unwind by itself (section 8.3), and that difference is
       ;; the whole test.
       (doseq [rel (take (or (opt i "release") 0) handles)] (rel)))
     ;; `bind` is `early`'s counterpart for section 8.1's OTHER half.
     ;; Binding declaration belongs in `define`; this names the callback
     ;; that tries it from somewhere else.
     (when (= "activate" (opt i "bind")) (h/bind! i "p" (fn [_ _] nil)))
     ;; `mark` registers N FOREIGN releases - section 8.3's `release`, the
     ;; half `acquire` cannot exercise - each recording its own index as it
     ;; runs. THE RECORDED LIST IS THE ONLY THING THAT DISTINGUISHES A
     ;; REVERSE UNWIND FROM A FORWARD ONE.
     (h/state-put! i "unwound" [])
     (doseq [k (range (or (opt i "mark") 0))]
       (h/release! i (fn []
                       ;; `markfail` makes the release RAISE - the only way
                       ;; section 8.3's `plugin_release_failed` and its
                       ;; `failed` status are reachable.
                       (when (t/truthy (opt i "markfail"))
                         (throw (RuntimeException. (str "release failed at " k))))
                       (h/state-update! i "unwound" [] #(conj % k))))))
   ;; `deactivate` completes the pair: the guard is on the PHASE, not on
   ;; "not define", and an entry exercising only one leaves the other's
   ;; mutation alive.
   "deactivate"
   (fn [i] (when (= "deactivate" (opt i "bind")) (h/bind! i "p" (fn [_ _] nil))))})

(defn- dep []
  {"name" "dep"
   "define" (fn [i]
              (h/state-put! i "count" 0)
              (declare-provides i)
              (let [exports (or (opt i "exports") {})]
                (doseq [k (t/sorted-keys exports)] (h/export! i k (t/get exports k)))))
   "activate" (fn [i] (h/acquire! i))})

(defn- provider []
  {"name" "provider"
   "define" (fn [i]
              (h/state-put! i "count" 0)
              (h/bind! i (or (opt i "point") "v")
                       (fn [_next _arg]
                         (if (t/has? (h/inst-options i) "value")
                           (opt i "value")
                           (h/inst-ref i)))
                       (opt i "band"))
              (declare-provides i))
   "activate" (fn [i] (h/acquire! i))})

(defn probes
  "Section 4.3's six probes. Their behaviour is as much the contract as the
  runner is - this is where twenty implementations of `noisy` are made to
  fail at the same callback in the same way."
  []
  [(probe) (noisy) (greedy) (dep) (provider)
   (record "slow") (record "other") (record "adapter") (record "late")])

(defn with-probes [] (p/make-catalog (probes)))

(defn- entry-field [host ref k]
  (when-let [e (h/instance host ref)] (t/get e k)))

(defn- do-call [host cmd ref point]
  (let [e (h/instance host ref)]
    (when (nil? e) (t/fail "plugin_not_loaded" (str "no such instance: " ref)))
    (case (t/get cmd "method")
      "bump" (do (h/entry-update! host (e "ref")
                                  #(assoc-in % ["state" "count"]
                                             (inc (or (get-in % ["state" "count"]) 0))))
                 [host nothing])
      "count" [host (or (get-in e ["state" "count"]) 0)]
      "unwound" [host (or (get-in e ["state" "unwound"]) [])]
      ;; Reached through the instance api, which is where section 6.6 puts
      ;; it - a plugin asks about itself.
      "position" [host (h/positionof host ref point)]
      ;; A release from OUTSIDE a lifecycle callback. THIS BRANCH USED TO
      ;; DO NOTHING, and its corpus row stayed green whatever `release` did
      ;; with its guard.
      "stray" (do (h/release! (h/exports host (str ref "/inst")) (fn [] nil))
                  [host nothing])
      [host nothing])))

(defn do-cmd [host cmd]
  (let [ref (t/get cmd "ref")
        point (t/get cmd "point")
        spec {"options" (t/get cmd "options") "order" (t/get cmd "order")
              "definition" (t/get cmd "definition") "tag" (t/get cmd "tag")}
        none (fn [f] (f) [host nothing])]
    (case (t/get cmd "do")
      "host" [(p/make-host {"catalog" (with-probes)
                            "reserved" (t/get cmd "reserved")
                            "keys" (t/get cmd "keys")
                            "defaults" (t/get cmd "defaults")
                            "profile" (t/get cmd "profile")
                            "points" (with-points (t/get cmd "points"))
                            ;; Section 11.3's strict reading. Absent means
                            ;; `restart`.
                            "dependency" (t/get cmd "dependency")})
              nothing]
      ;; Section 10.1's static registration: the definition ENTERS THE
      ;; CATALOG here, and registration is where its option shape is
      ;; validated (section 9.4) - before any load, so a malformed shape
      ;; fails at one moment in every host rather than whenever a document
      ;; happens to exercise the key.
      ;;
      ;; The catalog is pre-seeded with the probe set, so re-registering a
      ;; probe by name is the identity this command has always been;
      ;; `shape` is what makes it do work. A name the probe set does not
      ;; hold registers a bare definition - enough to reach the catalog,
      ;; and never loaded.
      ;; Section 4.2's three keys, all of them live. `probe` names the
      ;; PROBE whose callbacks back the definition and `name` is what the
      ;; definition is called - two keys that ten entries passed as equal
      ;; strings, so a driver ignoring `probe` passed them all.
      "define" (let [dname (t/get cmd "name")
                     source (if (t/has? cmd "probe") (t/get cmd "probe") dname)
                     found (first (filter #(= source (t/get % "name")) (probes)))
                     definition (if found (assoc found "name" dname) {"name" dname})
                     definition (if (t/has? cmd "shape")
                                  (assoc definition "shape" (t/get cmd "shape"))
                                  definition)]
                 (none #(h/define host definition)))
      "load" (none #(h/load host ref spec))
      ;; declare FIRST, so the ordering block and definition reach the
      ;; instance - `ready` walks the staircase, it does not carry
      ;; configuration of its own.
      "ready" (none #(do (h/declare host ref spec) (h/ready host ref)))
      "activate" (none #(h/activate host ref))
      "deactivate" (none #(h/deactivate host ref))
      "unload" (none #(h/unload host ref))
      "apply" (none #(h/apply host (t/get cmd "doc") (t/get cmd "profile")))
      "options" (none #(h/options host ref (t/get cmd "patch")))
      "close" (none #(h/close host))
      "list" [host (h/list host)]
      "emit" [host (h/emit host point (t/get cmd "arg"))]
      "chain" [host (h/call host point (t/get cmd "arg"))]
      "provider" [host (h/provider host point (t/get cmd "arg"))]
      "shadowed" [host (h/shadowed host point)]
      "export" [host (h/exports host (t/get cmd "key"))]
      "capability" [host (h/capability host (t/get cmd "name"))]
      "trace" [host (h/trace host)]
      ;; Section 9.1's host-owned path: the embedding host installing the
      ;; instance whose name it reserved.
      "hostdeclare" [host ((h/hostdeclare host ref spec) "ref")]
      "declare" [host ((h/declare host ref spec) "ref")]
      "order" [host (h/order host point)]
      "seq" [host (entry-field host ref "seq")]
      "pos" [host (entry-field host ref "pos")]
      "inner" [host (when-let [inner (entry-field host ref "inner")] (h/list inner))]
      "call" (do-call host cmd ref point)
      (throw (RuntimeException. (str "unknown driver command: " (t/get cmd "do")))))))

(defn drive
  "Run a command list and return section 4.5's observable. Stops at the
  first raise; the entry's `err` matches its code."
  [cmds]
  (let [host0 (p/make-host {"catalog" (with-probes) "points" (with-points)})
        ;; Section 4.5: `result` is the value of THE LAST COMMAND THAT
        ;; PRODUCES ONE. Storing it and continuing - rather than returning
        ;; at the first producing command - is what lets an entry emit and
        ;; then inspect, which most of `point` needs.
        [host last]
        (reduce (fn [[host last] cmd]
                  (try
                    (let [[next value] (do-cmd host cmd)]
                      [next (if (= nothing value) last value)])
                    (catch Exception e
                      ;; Section 4.1: `catch` records the raise and lets
                      ;; the run continue, which is the only way to observe
                      ;; a `failed` instance - section 5.2's whole claim is
                      ;; that it stays registered and inspectable.
                      (if (= true (t/get cmd "catch")) [host last] (throw e)))))
                [host0 nil]
                cmds)]
    (h/observable host last)))
