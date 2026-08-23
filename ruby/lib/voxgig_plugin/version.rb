# frozen_string_literal: true

# Versions and ranges (section 11.2).
#
# TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
# concrete version. A requirement declares `range`. A requirement is
# satisfied when the names match, the `match` passes, and:
#
#   the provider's `version` falls inside the requirement's `range`.
#
# That is the whole rule. There is no third field and no second
# comparison - an earlier draft added a provider-side `compat` range,
# which left three values and no statement of how they combine, and three
# defensible readings of one declaration is worse than the ambiguity it
# was introduced to fix.

require_relative 'types'

module VoxgigPlugin
  VERSION_RE = /\A(\d+)(?:\.(\d+))?(?:\.(\d+))?\z/.freeze

  # Two forms and no more (section 11.2):
  #
  #   '2.1'    >= 2.1.0 and < 3.0.0
  #   '~2.1'   >= 2.1.0 and < 2.2.0
  def self.parse_range(range)
    unless range.is_a?(String) && !range.empty?
      fail_with('plugin_bad_range', "invalid range: #{range}", { 'range' => range })
    end

    tilde = range.start_with?('~')
    body = tilde ? range[1..] : range
    m = VERSION_RE.match(body)
    if m.nil?
      fail_with('plugin_bad_range', "invalid range: #{range}", { 'range' => range })
    end

    major = m[1].to_i
    minor = m[2].nil? ? 0 : m[2].to_i
    patch = m[3].nil? ? 0 : m[3].to_i

    lo = [major, minor, patch]
    hi = tilde ? [major, minor + 1, 0] : [major + 1, 0, 0]
    { 'lo' => lo, 'hi' => hi }
  end

  def self.parse_version(version)
    unless version.is_a?(String)
      fail_with('plugin_bad_range', "invalid version: #{version}",
                { 'version' => version })
    end
    m = VERSION_RE.match(version)
    if m.nil?
      fail_with('plugin_bad_range', "invalid version: #{version}",
                { 'version' => version })
    end
    [m[1].to_i, m[2].nil? ? 0 : m[2].to_i, m[3].nil? ? 0 : m[3].to_i]
  end

  # The one satisfaction predicate: lo <= version < hi.
  def self.satisfies(version, range)
    v = parse_version(version)
    r = parse_range(range)
    version_cmp(v, r['lo']) >= 0 && version_cmp(v, r['hi']) < 0
  end

  # satisfies for the internal callers that treat an unparseable version
  # or range as "does not satisfy" - Capability and Graph, both of which
  # run over data the corpus has already admitted.
  def self.satisfiesq(version, range)
    satisfies(version, range)
  rescue PluginError
    false
  end

  def self.version_cmp(a, b)
    3.times do |i|
      x = a[i] || 0
      y = b[i] || 0
      return x < y ? -1 : 1 if x != y
    end
    0
  end
end
