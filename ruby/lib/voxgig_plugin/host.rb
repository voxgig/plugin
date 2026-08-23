# frozen_string_literal: true

# The host: the lifecycle state machine (section 5), extension points
# (section 6), and resource capture (section 8).
#
# TWO RULES SHAPE EVERY METHOD BELOW.
#
# Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
# never interleaved; a transition triggered from inside a lifecycle
# callback is `plugin_reentrant`. A hard rule, because it is the only way
# the semantics can be identical in Go, in Ruby and in single-threaded
# JavaScript.
#
# Reconciliation is EAGER (section 18's portability budget). A transition
# settles by running the state machine to a fixed point, not by
# suspending on a promise.

require_relative 'types'
require_relative 'ref'
require_relative 'catalog'
require_relative 'order'
require_relative 'point'
require_relative 'export'
require_relative 'capability'
require_relative 'config'
require_relative 'depend'

module VoxgigPlugin
  # What a definition's callbacks see. Deliberately not the internal
  # record: a plugin that could reach `status` could also write it.
  class Inst
    attr_reader :ref, :name, :tag

    def initialize(host, entry)
      @host = host
      @entry = entry
      @ref = entry['ref']
      parsed = VoxgigPlugin.parse_ref(entry['ref'])
      @name = parsed['name']
      @tag = parsed['tag']
    end

    def options
      @entry['options']
    end

    def state
      @entry['state']
    end

    def host
      @host
    end

    # Foreign resources the host did not hand out are registered
    # explicitly (section 8.3); host calls are recorded automatically.
    #
    # SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
    # resources CURRENTLY HELD, so an entry that is registered and then
    # unwound must leave the count where it found it.
    def release(&fn)
      unless @host.intransition?
        VoxgigPlugin.fail_with('plugin_release_scope',
                               'release called outside activate')
      end
      host = @host
      done = [false]
      @entry['scope'] << lambda {
        unless done[0]
          done[0] = true
          host.open_dec
          fn.call
        end
      }
      host.open_inc
    end

    # The synthetic counter the driver owns, so "what is open" is data
    # rather than an assertion each port words differently.
    #
    # Returns its own release, so a plugin can hand one back early. The
    # scope still holds the entry and unwinding it twice is a no-op -
    # releasing early must not make teardown wrong.
    def acquire
      unless @host.intransition?
        VoxgigPlugin.fail_with('plugin_release_scope',
                               'acquire called outside activate')
      end
      host = @host
      done = [false]
      rel = lambda {
        unless done[0]
          done[0] = true
          host.open_dec
        end
      }
      @entry['scope'] << rel
      host.open_inc
      rel
    end

    # Bind into a host point. Declared in `define`; the host inserts it
    # only after `activate` returns successfully (section 8.1), which is
    # why a failing activate leaves no live binding behind.
    def bind(point, fn, band = nil)
      unless @host.point?(point)
        VoxgigPlugin.fail_with('plugin_point_unknown', "no such point: #{point}",
                               { 'point' => point })
      end
      @entry['bindings'] << { 'ref' => @ref, 'point' => point, 'fn' => fn,
                              'band' => band || 0 }
    end

    # Published for other plugins and for the application (section 11).
    def export(key, value)
      @entry['exports'][key] = value
    end

    # What this instance can do for others (section 11.1).
    def provides(prov)
      @entry['provides'] << prov
    end

    # Where this binding landed (section 6.6) - the plugin-side
    # counterpart to a host pin. THE HOST DOES NOT POLICE THIS; it just
    # makes the fact available. Verification tells a plugin it was
    # misplaced; a pin (section 7) stops the misplacement from being
    # expressible at all. The two are not substitutes.
    def position(point)
      @host.positionof(@ref, point)
    end

    # AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER ONE
    # OWNS THE INNER ONE'S LIFETIME. Registering the teardown in the
    # instance scope is what makes that true rather than aspirational.
    def nest(nestopts = nil)
      unless @host.intransition?
        VoxgigPlugin.fail_with('plugin_release_scope',
                               'nest called outside a lifecycle callback')
      end
      inner = Host.new(nestopts)
      @entry['scope'] << -> { inner.close }
      @entry['inner'] = inner
      inner
    end
  end

  class Host
    attr_reader :catalog

    def initialize(options = nil)
      @opts = options || {}
      @dependency = @opts['dependency'] || 'restart'
      # Set for the duration of a bulk teardown, so `held` knows this is
      # a coordinated operation rather than an ad-hoc deactivation.
      @coordinated = false

      @catalog = @opts['catalog'] || VoxgigPlugin.make_catalog
      @reserved = @opts['reserved'] || []
      @points = @opts['points'] || {}

      @inst = {}
      @log = []
      # Section 14: the lifecycle event record. `seq` distinguishes ONE
      # INCARNATION of stripe$test from the next, which is the whole
      # reason it is not `pos` (section 4 rule 4).
      @events = []
      @seqn = 0
      @open = 0
      @intransition = false
    end

    def intransition?
      @intransition
    end

    def point?(name)
      @points.key?(name)
    end

    def open_inc
      @open += 1
    end

    def open_dec
      @open -= 1
    end

    # --- observation ------------------------------------------------

    # Introspection NEVER advances the state (section 5.2). A status page
    # must not be a way to accidentally import twenty packages.
    def list
      @inst.keys.sort.each_with_object({}) { |r, o| o[r] = @inst[r]['status'] }
    end

    def instance(ref)
      @inst[VoxgigPlugin.canon_ref(ref)]
    end

    def trace
      @events.dup
    end

    def observable(result = nil)
      { 'status' => list, 'open' => @open, 'log' => @log.dup,
        'result' => result }
    end

    # --- the state machine ------------------------------------------

    def guard
      return unless @intransition

      VoxgigPlugin.fail_with(
        'plugin_reentrant',
        'transition attempted from inside a lifecycle callback'
      )
    end

    def need(ref)
      r = VoxgigPlugin.canon_ref(ref)
      entry = @inst[r]
      if entry.nil?
        VoxgigPlugin.fail_with('plugin_not_loaded', "no such instance: #{r}",
                               { 'ref' => r })
      end
      entry
    end

    def checkreserved(ref)
      return if @reserved.empty?
      return unless @reserved.include?(VoxgigPlugin.refname(ref))

      VoxgigPlugin.fail_with('plugin_ref_reserved',
                             "ref is reserved by the host: #{ref}",
                             { 'ref' => ref })
    end

    def run(entry, callback, phase)
      fn = entry['def'][callback]
      @log << "#{entry['ref']}:#{phase}"
      @events << { 'ref' => entry['ref'], 'event' => phase,
                   'seq' => entry['seq'], 'status' => entry['status'] }
      return unless fn.respond_to?(:call)

      @intransition = true
      begin
        fn.call(Inst.new(self, entry))
      ensure
        @intransition = false
      end
    end

    # AUTO-TAGGING IS EXPLICIT (section 4 rule 3). `declare('stripe',
    # {'tag' => '?'})` assigns the LOWEST UNUSED POSITIVE INTEGER tag and
    # returns the assigned pair. Without `'?'`, a collision is an error.
    def autotag(name)
      n = 1
      loop do
        cand = VoxgigPlugin.format_ref(name, n.to_s)
        return cand unless @inst.key?(cand)

        n += 1
      end
    end

    def declare(ref, spec = nil)
      spec ||= {}
      ref = autotag(VoxgigPlugin.refname(VoxgigPlugin.canon_ref(ref))) if spec['tag'] == '?'
      r = VoxgigPlugin.canon_ref(ref)
      checkreserved(r)
      defname = spec['definition'] || VoxgigPlugin.refname(r)
      definition = @catalog.get(defname)
      if definition.nil?
        VoxgigPlugin.fail_with('plugin_unknown_definition',
                               "not in catalog: #{defname}", { 'name' => defname })
      end

      existing = @inst[r]
      unless existing.nil?
        # Section 4 rule 1: a pair addresses at most one instance.
        # Re-declaring the SAME definition is the idempotent case; a
        # different one is a duplicate, not a silent overwrite (seneca)
        # and not an impossibility (sdkgen).
        if existing['def']['name'] != definition['name']
          VoxgigPlugin.fail_with('plugin_ref_duplicate',
                                 "instance already declared: #{r}", { 'ref' => r })
        end
        return existing
      end

      entry = {
        'ref' => r, 'def' => definition, 'status' => 'declared',
        'pos' => spec['pos'].nil? ? @inst.length : spec['pos'],
        'seq' => @seqn,
        'options' => spec['options'] || {},
        'state' => {}, 'order' => spec['order'], 'unmet' => [], 'scope' => [],
        'bindings' => [], 'exports' => {}, 'provides' => [], 'inner' => nil
      }
      @seqn += 1
      @inst[r] = entry
      entry
    end

    def load(ref, spec = nil)
      guard
      spec ||= {}
      entry = declare(ref, spec)
      return entry if entry['status'] != 'declared' # idempotent trivially

      entry['options'] = spec['options'] if spec['options']
      begin
        run(entry, 'define', 'define')
      rescue StandardError
        entry['status'] = 'failed'
        raise
      end
      entry['status'] = 'loaded'

      # AT LOAD, and before anything runs: a cycle through
      # restart-causing requirements does not settle, and the only safe
      # time to report a non-terminating reconcile is before it starts
      # (section 11.3). `provides` is populated by `define`, which has
      # just run, so this is the first moment the graph is complete.
      begin
        VoxgigPlugin.checkcycle(graphnodes)
      rescue StandardError
        entry['status'] = 'failed'
        raise
      end
      entry
    end

    # The requirement graph as plain data, for the pure detector.
    def graphnodes
      @inst.keys.sort.map do |r|
        { 'ref' => r,
          'provides' => @inst[r]['provides'].map { |p| p['name'] },
          'requires' => VoxgigPlugin.requirements(@inst[r]['options']) }
      end
    end

    def activate(ref)
      guard
      entry = need(ref)
      return entry if entry['status'] == 'live' # no-op returning success

      if entry['status'] == 'failed'
        VoxgigPlugin.fail_with('plugin_bad_state',
                               "instance has failed: #{entry['ref']}",
                               { 'ref' => entry['ref'] })
      end
      load(entry['ref']) if entry['status'] == 'declared'

      # A declared requirement that is not live means `pending`:
      # activation is a STANDING REQUEST, not a one-shot event.
      unmet = unmetof(entry)
      unless unmet.empty?
        entry['unmet'] = unmet
        entry['status'] = 'pending'
        return entry
      end

      begin
        run(entry, 'activate', 'activate')
      rescue StandardError
        # Unwind whatever the partial activation captured, in reverse.
        unwind(entry)
        entry['status'] = 'failed'
        raise
      end
      entry['status'] = 'live'
      reconcile
      entry
    end

    def deactivate(ref)
      guard
      entry = need(ref)
      return entry if %w[loaded declared].include?(entry['status'])

      if entry['status'] == 'pending'
        # DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section 5.2).
        # It never reached activate, so it holds no scope and no live
        # bindings; running the definition's deactivate there would be
        # teardown without matching setup, which plugins are not written
        # to survive and which could fail an instance that had done
        # nothing wrong. It cannot fail.
        entry['status'] = 'loaded'
        entry['unmet'] = []
        return entry
      end

      held(entry)
      cascade(entry, {})

      begin
        run(entry, 'deactivate', 'deactivate')
      rescue StandardError
        unwind(entry)
        entry['status'] = 'failed'
        raise
      end
      unwind(entry)
      entry['status'] = 'loaded'
      reconcile
      entry
    end

    def unload(ref)
      guard
      entry = need(ref)
      if %w[live pending].include?(entry['status'])
        if entry['status'] == 'live'
          held(entry)
          cascade(entry, {})
          begin
            run(entry, 'deactivate', 'deactivate')
          rescue StandardError
            # Section 5.2: ANY failure during a transition lands the
            # instance in `failed`, with the scope STILL FULLY UNWOUND -
            # and the instance STAYS REGISTERED, because `failed` is a
            # state an operator has to be able to see.
            unwind(entry)
            entry['status'] = 'failed'
            raise
          end
          unwind(entry)
        end
        entry['status'] = 'loaded'
      end
      if %w[loaded failed].include?(entry['status'])
        begin
          run(entry, 'close', 'close')
        ensure
          @inst.delete(entry['ref'])
        end
        return
      end
      @inst.delete(entry['ref'])
    end

    # Runs the whole forward path in one call (section 5.1).
    def ready(ref)
      guard
      r = VoxgigPlugin.canon_ref(ref)
      declare(r) unless @inst.key?(r)
      load(r) if @inst[r]['status'] == 'declared'
      activate(r)
    end

    # Bindings go live only when activation succeeds (section 8.1), so
    # the teardown is the exact inverse: reverse order, always.
    def unwind(entry)
      entry['scope'].reverse_each do |fn|
        fn.call
      rescue StandardError
        nil # a failing release is section 12's problem, not a leak here
      end
      entry['scope'] = []
    end

    # A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1). A
    # bare string is shorthand for `{name}`. A ref satisfies too, because
    # a host that genuinely needs a specific instance should not have to
    # invent a capability for it.
    def unmetof(entry)
      VoxgigPlugin.requirements(entry['options'])
                  .select { |r| VoxgigPlugin.gatesactivation(r) }
                  .select { |r| providersof(r).empty? }
                  .map { |r| r['name'] }
    end

    # The instance currently SELECTED for each of this one's
    # restart-causing requirements. A BINDING IS TO AN INSTANCE, not to a
    # capability (section 11.1): the selected one going away restarts a
    # `static` consumer even though a survivor is available.
    def boundproviders(entry)
      out = []
      VoxgigPlugin.requirements(entry['options']).each do |req|
        next unless VoxgigPlugin.restartsonloss(req)

        cands = providersof(req)
        out << cands[0]['ref'] if !cands.empty? && !out.include?(cands[0]['ref'])
      end
      out
    end

    # Live instances whose selected provider is `ref` and which would be
    # restarted by losing it.
    def consumersof(ref)
      @inst.keys.sort.select do |r|
        c = @inst[r]
        r != ref && c['status'] == 'live' && boundproviders(c).include?(ref)
      end
    end

    def providersof(req)
      cands = []
      want = VoxgigPlugin.canon(req['name'])
      @inst.keys.sort.each do |ref|
        target = @inst[ref]
        next unless target['status'] == 'live'

        # A ref satisfies directly.
        if ref == want
          cands << { 'ref' => ref, 'pos' => target['pos'],
                     'provides' => { 'name' => req['name'] } }
          next
        end
        target['provides'].each do |prov|
          cands << { 'ref' => ref, 'pos' => target['pos'], 'provides' => prov } \
            if prov['name'] == req['name']
        end
      end
      VoxgigPlugin.resolve_capability(req, cands)
    end

    # CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).
    #
    # The cascade is part of the provider's own deactivation and runs
    # BEFORE the provider's `deactivate` callback and scope unwind, so a
    # consumer's teardown can still call the thing it depends on -
    # flushing a buffer to the store it is about to lose is exactly what
    # a `deactivate` callback is for, and a cascade that fired after the
    # provider was already gone would make that impossible.
    def cascade(provider, seen)
      return if seen[provider['ref']]

      seen[provider['ref']] = true

      consumersof(provider['ref']).each do |r|
        consumer = @inst[r]
        next unless consumer['status'] == 'live'

        cascade(consumer, seen) # deepest-first
        begin
          run(consumer, 'deactivate', 'deactivate')
        rescue StandardError
          nil # section 12
        end
        unwind(consumer)
        consumer['status'] = 'pending'
        consumer['unmet'] = unmetof(consumer)
      end
    end

    # The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON
    # COORDINATED TEARDOWN. In a bulk operation that is removing the
    # holders too - `close`, or an `apply` plan whose own steps
    # deactivate them - it is suspended for exactly those holders, and
    # the teardown still runs consumers before providers.
    def held(entry)
      return unless @dependency == 'hold'
      return if @coordinated

      holders = consumersof(entry['ref'])
      return if holders.empty?

      VoxgigPlugin.fail_with('plugin_dependency_held',
                             "instance is required by live consumers: #{entry['ref']}",
                             { 'ref' => entry['ref'], 'holders' => holders })
    end

    # EAGER reconciliation: run to a fixed point rather than scheduling.
    #
    # Two directions, and both are the reason `pending` exists.
    # Activation is a STANDING REQUEST, not a one-shot event.
    def reconcile
      moved = true
      rounds = 0
      while moved
        moved = false
        rounds += 1
        break if rounds > 1000

        # Losses first, so a cascade settles in one pass rather than
        # alternating with re-activations.
        @inst.keys.sort.each do |r|
          entry = @inst[r]
          next unless entry['status'] == 'live'

          lost = VoxgigPlugin.requirements(entry['options'])
                             .select { |q| VoxgigPlugin.gatesactivation(q) }
                             .select { |q| providersof(q).empty? }
          next if lost.empty?
          # POLICY IS PER REQUIREMENT, not per instance (section 11.3). A
          # `dynamic` requirement whose provider is gone leaves the
          # consumer LIVE and notified.
          next unless lost.any? { |q| VoxgigPlugin.restartsonloss(q) }

          begin
            run(entry, 'deactivate', 'deactivate')
          rescue StandardError
            nil
          end
          unwind(entry)
          entry['status'] = 'pending'
          entry['unmet'] = unmetof(entry)
          moved = true
        end

        @inst.keys.sort.each do |r|
          entry = @inst[r]
          next unless entry['status'] == 'pending'
          next unless unmetof(entry).empty?

          begin
            run(entry, 'activate', 'activate')
            entry['status'] = 'live'
            entry['unmet'] = []
            moved = true
          rescue StandardError
            unwind(entry)
            entry['status'] = 'failed'
            moved = true
          end
        end
      end
    end

    # --- ordering ---------------------------------------------------

    def order(point = nil)
      bindings = @inst.keys.select { |r| @inst[r]['status'] == 'live' }
                      .map do |r|
        { 'ref' => r, 'pos' => @inst[r]['pos'], 'order' => @inst[r]['order'] }
      end
      spec = point ? @points[point] : nil
      VoxgigPlugin.resolve_order(bindings, spec ? spec['pin'] : nil)
    end

    # --- points -----------------------------------------------------

    # Live bindings on a point, in resolved order. Recomputed on any
    # change to the live set (section 7) rather than cached at startup -
    # the bug a host discovers only when something deactivates in
    # production.
    def bound(point)
      out = []
      order(point).each do |ref|
        entry = @inst[ref]
        # The band is the INSTANCE's ordering block (section 7), stamped
        # by the host. A plugin passing its own would be ranking itself
        # above the order its document declared.
        block = entry['order'] || {}
        band = block['band'].is_a?(Integer) ? block['band'] : 0
        entry['bindings'].each do |b|
          out << b.merge('band' => band) if b['point'] == point
        end
      end
      out
    end

    def pointspec(point, want)
      spec = @points[point]
      if spec.nil?
        VoxgigPlugin.fail_with('plugin_point_unknown', "no such point: #{point}",
                               { 'point' => point })
      end
      kind = spec['kind']
      if want == 'hook'
        # A point with no declared kind is a hook, which is what makes
        # `{}` the minimal point declaration.
        if kind && kind != 'hook'
          VoxgigPlugin.fail_with('plugin_point_kind', "point is not a hook: #{point}",
                                 { 'point' => point, 'kind' => kind })
        end
        return spec
      end
      unless kind == want
        VoxgigPlugin.fail_with('plugin_point_kind',
                               "point is not a #{want}: #{point}",
                               { 'point' => point, 'kind' => kind })
      end
      spec
    end

    def emit(point, arg = nil)
      spec = pointspec(point, 'hook')
      VoxgigPlugin.point_emit(bound(point), spec['mode'] || 'emit', arg)
    end

    def call(point, *args)
      spec = pointspec(point, 'chain')
      base = spec['base'] || ->(*a) { a[0] }
      VoxgigPlugin.compose(bound(point), base).call(*args)
    end

    def provider(point, *args)
      spec = pointspec(point, 'provider')
      pick = VoxgigPlugin.point_provider(bound(point), spec)
      return spec['default'] if pick['winner'].nil?

      pick['winner']['fn'].call(*args)
    end

    # The losers are VISIBLE rather than silently ignored (section 6.3).
    def shadowed(point)
      spec = @points[point]
      return [] if spec.nil?

      VoxgigPlugin.point_provider(bound(point), spec)['shadowed']
    end

    def exports(spec)
      all = []
      @inst.keys.sort.each do |ref|
        entry = @inst[ref]
        # Exports of a `loaded` (not live) instance are VISIBLE (11).
        next if %w[declared failed].include?(entry['status'])

        entry['exports'].keys.sort.each do |k|
          all << { 'ref' => ref, 'key' => k, 'value' => entry['exports'][k] }
        end
      end
      VoxgigPlugin.resolve_export(spec, all)
    end

    # The live providers of a capability, best-first (section 11.1).
    def capability(name)
      cands = []
      @inst.keys.sort.each do |ref|
        entry = @inst[ref]
        next unless entry['status'] == 'live'

        entry['provides'].each do |prov|
          cands << { 'ref' => ref, 'pos' => entry['pos'], 'provides' => prov } \
            if prov['name'] == name
        end
      end
      VoxgigPlugin.resolve_capability({ 'name' => name }, cands).map { |c| c['ref'] }
    end

    # --- documents --------------------------------------------------

    def apply(doc, profile = nil)
      guard
      profile ||= @opts['profile']
      norm = VoxgigPlugin.normalize_config(
        { 'doc' => doc, 'profile' => profile,
          'keys' => @opts['keys'], 'reserved' => @reserved }
      )

      norm['order'].each do |ref|
        ent = norm['instance'][ref]
        defaults = @opts['defaults'] || {}
        options = VoxgigPlugin.resolve_options(
          { 'ref' => ref, 'doc' => doc, 'profile' => profile,
            'shape' => shapeof(ref),
            'hostdefaults' => defaults[VoxgigPlugin.refname(ref)] }
        )

        existing = @inst[ref]
        wantlive = ent['active'] && ent['start'] == 'eager'

        # Toggling back to lazy or inactive returns it to `declared`, BY
        # UNLOADING IT (section 9.6). There is no loaded->declared
        # transition and there should not be one.
        unload(ref) if existing && !wantlive && existing['status'] != 'declared'

        declare(ref, { 'options' => options, 'order' => ent['order'],
                       'pos' => ent['pos'] })
        # REFILL rather than REBIND. A definition's callbacks close over
        # the options map they were handed at `define`; replacing the
        # reference here would leave every binding reading the values the
        # first apply gave it, and a re-applied document would silently
        # do nothing.
        refill(@inst[ref]['options'], options)
        @inst[ref]['order'] = ent['order']
        @inst[ref]['pos'] = ent['pos']

        ready(ref) if wantlive
      end
    end

    def shapeof(ref)
      definition = @catalog.get(VoxgigPlugin.refname(ref))
      definition ? definition['shape'] : nil
    end

    def options(ref, patch)
      guard
      entry = need(ref)
      previous = entry['options'].dup
      refill(entry['options'], VoxgigPlugin.resolve_options(
                                 { 'ref' => entry['ref'],
                                   'shape' => shapeof(entry['ref']),
                                   'doc' => {},
                                   'patch' => previous.merge(patch || {}) }
                               ))
      return unless entry['status'] == 'live'

      reconfigure = entry['def']['reconfigure']
      if reconfigure.respond_to?(:call)
        @intransition = true
        begin
          reconfigure.call(Inst.new(self, entry), entry['options'], previous)
        ensure
          @intransition = false
        end
      else
        # Always correct and sometimes expensive; `reconfigure` exists to
        # make the common case cheap (section 9.4).
        deactivate(entry['ref'])
        activate(entry['ref'])
      end
    end

    # Empty the target and refill it, so callers holding the reference
    # see the new values.
    def refill(target, source)
      target.clear
      (source || {}).each { |k, v| target[k] = v }
    end

    def close
      # A bulk teardown removing the holders too, so `hold` is suspended
      # for exactly those holders (section 11.3) - while the
      # consumers-first cascade still runs, which is the half that
      # matters.
      @coordinated = true
      begin
        @inst.keys.sort.reverse.each { |r| unload(r) }
      ensure
        @coordinated = false
      end
    end

    # The same record section 6.6 gives a plugin about itself, reachable
    # from outside for the corpus.
    def positionof(ref, point)
      entry = @inst[VoxgigPlugin.canon(ref)]
      if entry.nil?
        VoxgigPlugin.fail_with('plugin_not_loaded', "no such instance: #{ref}",
                               { 'ref' => ref })
      end
      ranked = order(point)
      index = ranked.index(entry['ref']) || -1
      { 'index' => index, 'count' => ranked.length,
        # Section 6.2 composes b1(b2(b3(base))) with the FIRST binding
        # OUTERMOST, so these are not index 0 and index count-1 the other
        # way round.
        'outermost' => index.zero?,
        'innermost' => index == ranked.length - 1 }
    end

    def define(definition)
      @catalog.add(definition)
    end
  end

  def self.make_host(options = nil)
    Host.new(options)
  end
end
