(ns voxgig.plugin.corpus
  "The corpus runner.

  Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
  exactly as every other port's runner does. No port needs a Node
  toolchain to run its tests, and this one does not get a private door into
  the source either.

  A group name selects the subject. That is the whole dispatch, and it is
  deliberately dumb: a runner that inferred the subject from the entry's
  shape would silently run the wrong function when an entry was mistyped."
  (:require [voxgig.plugin.types :as t]
            [voxgig.plugin.json :as json]
            [clojure.string :as str]))

;; A sentinel for "this key was not present". `get` returns nil for both an
;; absent key and a JSON null, and `__UNDEF__` and `__NULL__` are different
;; assertions.
(def missing ::missing)

(defn corpus [] (json/parse (slurp "../spec/plugin.json")))

(defn section [spec nm]
  (let [sec (t/get (or (t/get spec "primary") {}) nm)]
    (when (nil? sec) (throw (RuntimeException. (str "no such corpus section: " nm))))
    (into {} (for [[group body] sec
                   :when (and (not= "DEF" group) (map? body)
                              (sequential? (t/get body "set")))]
               [group (t/get body "set")]))))

(defn label
  "A stable label, so a failure names the entry rather than an index."
  [group i entry]
  (or (t/get entry "id") (str group "#" i)))

(defn matches?
  "Partial match: every key the expectation names must agree, and keys it
  does not name are ignored. `__EXISTS__` asserts presence without pinning
  a value; `/re/` matches a string as a regular expression."
  [expect actual]
  (cond
    (= "__EXISTS__" expect) (and (not= missing actual) (some? actual))
    (= "__UNDEF__" expect) (= missing actual)
    (= "__NULL__" expect) (and (not= missing actual) (nil? actual))
    :else
    (let [actual (if (= missing actual) nil actual)]
      (cond
        (and (string? expect) (< 2 (count expect))
             (str/starts-with? expect "/") (str/ends-with? expect "/"))
        (and (string? actual)
             (some? (re-find (re-pattern (subs expect 1 (dec (count expect)))) actual)))

        (sequential? expect)
        (and (sequential? actual) (= (count expect) (count actual))
             (every? identity (map matches? expect actual)))

        (map? expect)
        (and (map? actual)
             (every? (fn [k] (matches? (t/get expect k)
                                       (if (contains? actual k) (actual k) missing)))
                     (t/sorted-keys expect)))

        :else (t/same expect actual)))))

(defn- err-verdict [entry e]
  (let [want (t/get entry "err")
        ;; Errors compare by CODE (section 12). Message wording is a port's
        ;; own business, and pinning it would make every translation a
        ;; corpus change.
        got (t/code-of e)]
    (cond
      (and (not= true want) (not= got want))
      (str "expected code " want ", got " got " (" (t/message-of e) ")")

      (and (t/has? entry "match")
           (not (matches? (t/get entry "match")
                          {"err" {"code" got "message" (t/message-of e)
                                  "name" "PluginError"}})))
      (str "error did not match " (t/encode (t/get entry "match")) ", got code=" got)

      :else nil)))

(defn- ok-verdict [entry value]
  (cond
    (t/has? entry "err") (str "expected a raise, got: " (t/encode value))

    (and (t/has? entry "out") (not (t/same (t/get entry "out") value)))
    (str "expected " (t/encode (t/get entry "out")) ", got " (t/encode value))

    (and (t/has? entry "match")
         (not (matches? (t/get entry "match")
                        {"in" (t/get entry "in") "out" value})))
    (str "did not match " (t/encode (t/get entry "match")) ", got out=" (t/encode value))

    (and (not (t/has? entry "out")) (not (t/has? entry "match")))
    "entry asserts nothing"

    :else nil))

(defn check
  "Run one entry against a subject and report the disagreement, if any.

  The three combinations the spec format allows are enforced here as well
  as at build time, because a runner that quietly accepted `err` beside
  `out` would let a contradictory entry pass."
  [entry subject]
  (if (and (t/has? entry "err") (t/has? entry "out"))
    "entry has both err and out"
    (let [outcome (try [:ok (subject entry)] (catch Exception e [:raised e]))]
      (if (= :ok (first outcome))
        (ok-verdict entry (second outcome))
        (if (t/has? entry "err")
          (err-verdict entry (second outcome))
          (str "unexpected raise: " (t/code-of (second outcome)) " "
               (t/message-of (second outcome))))))))
