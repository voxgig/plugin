# frozen_string_literal: true

# The whole suite: pure sections by direct call, driver sections by
# command list, and a coverage guard above both.
#
# A plain runner rather than minitest, for the same reason the port has
# no gems: a conformance suite whose only job is to run one corpus and
# report which entries disagree does not need a framework, and adding one
# would make `make test` depend on a bundle nobody else in this repo has.

require 'json'
require 'voxgig_plugin'
require 'corpus'
require 'driver'

FAILURES = []
RAN = { sections: 0, entries: 0 }

def report(name, group, i, entry, why)
  FAILURES << "#{name}/#{Corpus.label(group, i, entry)}: #{why}"
end

# Dispatch every group, and fail on a group the runner does not know - a
# group silently not run is worse than a failure.
def run_section(name, subject)
  groups = Corpus.section(name)
  RAN[:sections] += 1
  groups.keys.sort.each do |group|
    fn = subject[group]
    if fn.nil?
      FAILURES << "#{name}: corpus group with no subject: #{group}"
      next
    end
    groups[group].each_with_index do |entry, i|
      RAN[:entries] += 1
      why = Corpus.check(entry) { |e| fn.call(e) }
      report(name, group, i, entry, why) if why
    end
  end
end

# ---- pure sections --------------------------------------------------

run_section('ref', {
              'parse' => ->(e) { VoxgigPlugin.parse_ref(e['in']) },
              'parsebad' => ->(e) { VoxgigPlugin.parse_ref(e['in']) },
              'format' => ->(e) { VoxgigPlugin.format_ref((e['args'] || [])[0], (e['args'] || [])[1]) },
              'formatbad' => ->(e) { VoxgigPlugin.format_ref((e['args'] || [])[0], (e['args'] || [])[1]) },
              'canon' => ->(e) { VoxgigPlugin.canon_ref(e['in']) },
              'name' => ->(e) { VoxgigPlugin.check_name(e['in']) },
              'tag' => ->(e) { VoxgigPlugin.check_tag(e['in']) },
              'bound' => ->(e) { VoxgigPlugin.check_name(e['in']) },
              'boundtag' => ->(e) { VoxgigPlugin.check_tag(e['in']) }
            })

env = ->(e) { VoxgigPlugin.apply_env(e['in']) }
run_section('env', {
              'option' => env, 'value' => env, 'toggle' => env,
              'profile' => env, 'ambiguous' => env, 'reserved' => env
            })

rng = ->(e) { VoxgigPlugin.parse_range(e['in']) }
run_section('version', {
              'range' => rng, 'rangebad' => rng,
              'satisfies' => ->(e) { VoxgigPlugin.satisfies(e['in']['version'], e['in']['range']) }
            })

cap = ->(e) { VoxgigPlugin.resolve_capability(e['in']['req'], e['in']['candidates']) }
run_section('capability', { 'match' => cap, 'nested' => cap, 'rank' => cap })

graph = ->(e) { VoxgigPlugin.resolve_graph(e['in']) }
run_section('graph', { 'resolve' => graph, 'blocked' => graph })

run_section('resolve', {
              'candidates' => ->(e) { VoxgigPlugin.resolve_candidates(e['in']['name'], e['in']['sources']) },
              'from' => ->(e) { VoxgigPlugin.resolve_from(e['in']) }
            })

# `config` picks its subject by group PREFIX rather than by name, because
# the two functions split the section cleanly.
configgroups = Corpus.section('config')
RAN[:sections] += 1
configgroups.keys.sort.each do |group|
  fn = if group.start_with?('norm')
         ->(e) { VoxgigPlugin.normalize_config(e['in']) }
       elsif group.start_with?('opt')
         ->(e) { VoxgigPlugin.resolve_options(e['in']) }
       end
  if fn.nil?
    FAILURES << "config: corpus group with no subject: #{group}"
    next
  end
  configgroups[group].each_with_index do |entry, i|
    RAN[:entries] += 1
    why = Corpus.check(entry) { |e| fn.call(e) }
    report('config', group, i, entry, why) if why
  end
end

# ---- driver sections ------------------------------------------------

DRIVER_SECTIONS = %w[
  lifecycle order point export depend
  declare state resource nest trace apply error
].freeze

DRIVER_SECTIONS.each do |name|
  groups = Corpus.section(name)
  RAN[:sections] += 1
  groups.keys.sort.each do |group|
    groups[group].each_with_index do |entry, i|
      RAN[:entries] += 1
      unless entry['in'].is_a?(Array)
        report(name, group, i, entry, 'driver entry without a command list in `in`')
        next
      end
      why = Corpus.check(entry) { |e| Driver.drive(e['in']) }
      report(name, group, i, entry, why) if why
    end
  end
end

# ---- coverage -------------------------------------------------------
#
# EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails on
# a GROUP with no subject; this closes the level above, because a whole
# SECTION the runner never mentions is a section silently not run.

PURE_SECTIONS = %w[ref env version capability graph resolve config].freeze
spec = Corpus.corpus
primary = spec['primary'] || {}

# The corpus metadata block is what turns on strict entry validation in
# every runner, so a corpus that lost it must not silently downgrade this
# port's checking.
unless (spec['PLUGIN'] || {})['version'] == 1
  FAILURES << 'corpus PLUGIN.version must be 1'
end

run = PURE_SECTIONS + DRIVER_SECTIONS
missing = primary.keys.reject { |n| run.include?(n) }.sort
FAILURES << "corpus sections no test runs: #{missing.join(', ')}" unless missing.empty?
extra = run.reject { |n| primary.key?(n) }.sort
unless extra.empty?
  FAILURES << "tests name sections the corpus does not have: #{extra.join(', ')}"
end

# A floor, not a fixture: the corpus grows, and a run that suddenly
# covers a fraction of it is the failure worth catching.
if RAN[:entries] < 400
  FAILURES << "only #{RAN[:entries]} corpus entries reachable"
end

# ---- report ---------------------------------------------------------

if FAILURES.empty?
  puts "ruby: #{RAN[:entries]} corpus entries across #{RAN[:sections]} sections, all pass"
  exit 0
end

FAILURES.each { |f| warn f }
warn "\nruby: #{FAILURES.length} failure(s) of #{RAN[:entries]} entries"
exit 1
