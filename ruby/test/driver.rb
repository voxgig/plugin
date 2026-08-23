# frozen_string_literal: true

# The driver (DOCS.md section 4).
#
# Every port implements this same small thing and nothing else is
# port-specific: the probe catalog, the command interpreter, and the
# canonical observable.

require 'voxgig_plugin'

module Driver
  # A sentinel for "this command produced nothing", so a command that
  # legitimately produces nil - `export` of a missing key - still
  # overwrites the previous result.
  NOTHING = Object.new

  # Section 4.3's six probes. Their behaviour is as much the contract as
  # the runner is - this is where twenty implementations of `noisy` are
  # made to fail at the same callback in the same way.
  def self.probes
    record = lambda do |name|
      { 'name' => name,
        'define' => ->(i) { i.state['count'] = i.state['count'] || 0 },
        'activate' => ->(i) { i.acquire } }
    end

    probe = {
      'name' => 'probe',
      'define' => lambda do |i|
        i.state['count'] = i.state['count'] || 0
        band = i.options['band']
        # One hook binding (`p`) and one chain wrap (`c`) - the workhorse
        # shape DOCS.md section 4.3 specifies.
        i.bind('p', ->(_arg = nil) { i.state['count'] = (i.state['count'] || 0) + 1 },
               band)
        # Wrap AFTER next, so the result spells the nesting left to
        # right: outermost first. Wrapping the ARGUMENT instead would
        # spell it backwards and make every chain expectation read wrong.
        i.bind('c', ->(nxt, v) { "#{i.options['wrap'] || ':'}#{nxt.call(v)}" }, band)
        i.export('client', i.ref)
        # The instance api itself, so the driver's `stray` command can
        # call `release` from OUTSIDE a lifecycle callback.
        i.export('inst', i)
        declareprovides(i)
      end,
      'activate' => lambda do |i|
        i.acquire
        # Section 6.5: an instance that is itself a host. The outer owns
        # the inner's lifetime - registered in the scope, so it closes on
        # deactivate in the same reverse unwind as every other resource.
        nest = i.options['nest']
        next if nest.nil?

        inner = i.nest({ 'points' => withpoints })
        probes.each { |d| inner.catalog.add(d) }
        nest.each { |r| inner.ready(r) }
      end
    }

    noisy = {
      'name' => 'noisy',
      'define' => lambda do |i|
        i.state['count'] = i.state['count'] || 0
        boom(i, 'define')
      end,
      'activate' => lambda do |i|
        # Acquire BEFORE the raise, so a failing activate has something
        # to leak if the scope does not unwind - which is the whole point
        # of the entry that asserts open == 0 afterwards.
        i.acquire
        reenter(i, 'activate')
        boom(i, 'activate')
      end,
      'deactivate' => ->(i) { boom(i, 'deactivate') },
      'close' => ->(i) { boom(i, 'close') }
    }

    greedy = {
      'name' => 'greedy',
      'define' => lambda do |i|
        i.state['count'] = 0
        # Section 8.1 puts resource capture in `activate`. `early` NAMES
        # the call that reaches for it in `define`, because `acquire` and
        # `release` carry the guard separately.
        i.acquire if i.options['early'] == 'acquire'
        i.release { nil } if i.options['early'] == 'release'
      end,
      'activate' => lambda do |i|
        n = i.options['acquire'] || 0
        rel = i.options['release'] || 0
        handles = Array.new(n) { i.acquire }
        # Release some explicitly; the DIFFERENCE is what the instance
        # scope must unwind by itself (section 8.3), and that difference
        # is the whole test.
        [rel, handles.length].min.times { |k| handles[k].call }

        # `mark` registers N FOREIGN releases - section 8.3's `release`,
        # the half `acquire` cannot exercise - each recording its own
        # index as it runs. THE RECORDED LIST IS THE ONLY THING THAT
        # DISTINGUISHES A REVERSE UNWIND FROM A FORWARD ONE.
        # `bind` is `early`'s counterpart for section 8.1's OTHER half.
        # Binding declaration belongs in `define`; this names the callback
        # that tries it from somewhere else.
        i.bind('p', ->(*_a) { nil }) if i.options['bind'] == 'activate'

        i.state['unwound'] = []
        (i.options['mark'] || 0).times do |k|
          i.release do
            # `markfail` makes the release RAISE - the only way section
            # 8.3's `plugin_release_failed` and its `failed` status are
            # reachable.
            raise "release failed at #{k}" if i.options['markfail']

            i.state['unwound'] << k
          end
        end
      end,
      # `deactivate` completes the pair: the guard is on the PHASE, not
      # on "not define", and an entry exercising only one leaves the
      # other's mutation alive.
      'deactivate' => lambda do |i|
        i.bind('p', ->(*_a) { nil }) if i.options['bind'] == 'deactivate'
      end
    }

    dep = {
      'name' => 'dep',
      'define' => lambda do |i|
        i.state['count'] = 0
        declareprovides(i)
        (i.options['exports'] || {}).keys.sort.each do |k|
          i.export(k, i.options['exports'][k])
        end
      end,
      'activate' => ->(i) { i.acquire }
    }

    provider = {
      'name' => 'provider',
      'define' => lambda do |i|
        i.state['count'] = 0
        point = i.options['point'] || 'v'
        i.bind(point,
               ->(*_a) { i.options.key?('value') ? i.options['value'] : i.ref },
               i.options['band'])
        declareprovides(i)
      end,
      'activate' => ->(i) { i.acquire }
    }

    [probe, noisy, greedy, dep, provider,
     record.call('slow'), record.call('other'), record.call('adapter'),
     record.call('late')]
  end

  def self.declareprovides(inst)
    (inst.options['provides'] || []).each { |p| inst.provides(p) }
  end

  def self.boom(inst, callback)
    return unless callback == inst.options['fail']

    # `bare` raises WITHOUT a code - the ordinary library error section
    # 12's `plugin_<phase>_failed` codes exist to wrap.
    raise "probe failed at #{callback}" if inst.options['bare']

    raise VoxgigPlugin::PluginError.new(
      inst.options['code'] || "plugin_#{callback}_failed",
      "probe failed at #{callback}"
    )
  end

  def self.reenter(inst, callback)
    return unless callback == inst.options['reenter']

    # A transition from inside a lifecycle callback (section 5.2).
    inst.host.activate(inst.ref)
  end

  # The points every driver host declares. DOCS.md section 4.3 defines
  # `probe` as binding one hook point (`p`) and wrapping one chain point
  # (`c`), so a host without them cannot load the probe at all - they are
  # part of the contract's baseline rather than a fixture convenience.
  # `v` is the provider point the `provider` probe defaults to.
  def self.basepoints
    { 'p' => { 'kind' => 'hook' },
      'c' => { 'kind' => 'chain', 'base' => ->(*a) { a[0] } },
      'v' => { 'kind' => 'provider' } }
  end

  def self.withpoints(extra = nil)
    out = basepoints
    # A `host` command REPLACES a base point rather than merging into it,
    # so an entry can redeclare `c` with its own base or `v` as exclusive
    # without inheriting the default's shape.
    (extra || {}).each { |k, v| out[k] = v }
    out
  end

  def self.withprobes
    VoxgigPlugin.make_catalog(probes)
  end

  # Run a command list and return section 4.5's observable. Stops at the
  # first raise; the entry's `err` matches its code.
  def self.drive(cmds)
    host = VoxgigPlugin.make_host({ 'catalog' => withprobes,
                                    'points' => withpoints })

    # Section 4.5: `result` is the value of THE LAST COMMAND THAT
    # PRODUCES ONE. Storing it and continuing - rather than returning at
    # the first producing command - is what lets an entry emit and then
    # inspect, which most of `point` needs.
    last = nil

    cmds.each do |cmd|
      begin
        host, value = docmd(host, cmd)
        last = value unless NOTHING.equal?(value)
      rescue StandardError
        # Section 4.1: `catch` records the raise and lets the run
        # continue, which is the only way to observe a `failed` instance
        # - section 5.2's whole claim is that it stays registered and
        # inspectable.
        raise unless cmd['catch'] == true
      end
    end
    host.observable(last)
  end

  def self.docmd(host, cmd)
    ref = cmd['ref']
    point = cmd['point']
    spec = { 'options' => cmd['options'], 'order' => cmd['order'],
             'definition' => cmd['definition'], 'tag' => cmd['tag'] }

    case cmd['do']
    when 'host'
      return [VoxgigPlugin.make_host(
        { 'catalog' => withprobes,
          'reserved' => cmd['reserved'], 'keys' => cmd['keys'],
          'defaults' => cmd['defaults'], 'profile' => cmd['profile'],
          'points' => withpoints(cmd['points']),
          # Section 11.3's strict reading. Absent means `restart`.
          'dependency' => cmd['dependency'] }
      ), NOTHING]
    when 'define'
      # The catalog is pre-seeded with the probe set; `define` names
      # which entry backs this definition.
      return [host, NOTHING]
    when 'load' then host.load(ref, spec)
    when 'ready'
      # declare FIRST, so the ordering block and definition reach the
      # instance - `ready` walks the staircase, it does not carry
      # configuration of its own.
      host.declare(ref, spec)
      host.ready(ref)
    when 'activate' then host.activate(ref)
    when 'deactivate' then host.deactivate(ref)
    when 'unload' then host.unload(ref)
    when 'apply' then host.apply(cmd['doc'], cmd['profile'])
    when 'options' then host.options(ref, cmd['patch'])
    when 'close' then host.close
    when 'list' then return [host, host.list]
    when 'emit' then return [host, host.emit(point, cmd['arg'])]
    when 'chain' then return [host, host.call(point, cmd['arg'])]
    when 'provider' then return [host, host.provider(point, cmd['arg'])]
    when 'shadowed' then return [host, host.shadowed(point)]
    when 'export' then return [host, host.exports(cmd['key'])]
    when 'capability' then return [host, host.capability(cmd['name'])]
    when 'trace' then return [host, host.trace]
    when 'hostdeclare'
      # Section 9.1's host-owned path: the embedding host installing the
      # instance whose name it reserved.
      return [host, host.hostdeclare(ref, spec)['ref']]
    when 'declare' then return [host, host.declare(ref, spec)['ref']]
    when 'order' then return [host, host.order(point)]
    when 'seq'
      entry = host.instance(ref)
      return [host, entry ? entry['seq'] : nil]
    when 'pos'
      entry = host.instance(ref)
      return [host, entry ? entry['pos'] : nil]
    when 'inner'
      entry = host.instance(ref)
      return [host, entry && entry['inner'] ? entry['inner'].list : nil]
    when 'call' then return docall(host, cmd, ref, point)
    else
      raise "unknown driver command: #{cmd['do']}"
    end

    [host, NOTHING]
  end

  def self.docall(host, cmd, ref, point)
    entry = host.instance(ref)
    if entry.nil?
      raise VoxgigPlugin::PluginError.new('plugin_not_loaded',
                                          "no such instance: #{ref}")
    end
    case cmd['method']
    when 'bump'
      entry['state']['count'] = (entry['state']['count'] || 0) + 1
      [host, NOTHING]
    when 'count' then [host, entry['state']['count'] || 0]
    when 'unwound' then [host, entry['state']['unwound'] || []]
    when 'position'
      # Reached through the instance api, which is where section 6.6 puts
      # it - a plugin asks about itself.
      [host, host.positionof(ref, point)]
    when 'stray'
      # A release from OUTSIDE a lifecycle callback. THIS BRANCH USED TO
      # DO NOTHING, and its corpus row stayed green whatever `release`
      # did with its guard.
      host.exports("#{ref}/inst").release { nil }
      [host, NOTHING]
    else
      [host, NOTHING]
    end
  end
end
