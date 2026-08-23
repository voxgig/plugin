# frozen_string_literal: true

# The corpus runner.
#
# Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
# exactly as every other port's runner does. No port needs a Node
# toolchain to run its tests, and this one does not get a private door
# into the source either.
#
# A group name selects the subject. That is the whole dispatch, and it is
# deliberately dumb: a runner that inferred the subject from the entry's
# shape would silently run the wrong function when an entry was mistyped.

require 'json'
require 'voxgig_plugin'

module Corpus
  SPEC = File.join(__dir__, '..', '..', 'spec', 'plugin.json')

  # A sentinel for "this key was not present". Ruby's Hash#[] returns nil
  # for both an absent key and a JSON null, and `__UNDEF__` and
  # `__NULL__` are different assertions.
  MISSING = Object.new

  def self.corpus
    JSON.parse(File.read(SPEC))
  end

  def self.section(name)
    spec = corpus
    sec = (spec['primary'] || {})[name]
    raise "no such corpus section: #{name}" if sec.nil?

    out = {}
    sec.each do |group, body|
      next if group == 'DEF'
      next unless body.is_a?(Hash) && body['set'].is_a?(Array)

      out[group] = body['set']
    end
    out
  end

  # A stable label, so a failure names the entry rather than an index.
  def self.label(group, i, entry)
    entry['id'] || "#{group}##{i}"
  end

  # Deep equality over spec values. Key order never matters; list order
  # always does.
  #
  # Ruby's `true == 1` is already false, so the bool guard other dynamic
  # ports need is not required here - but the JSON `1` vs `1.0`
  # distinction is not one Ruby draws either, and no corpus entry turns
  # on it.
  def self.same(a, b)
    if a.is_a?(Hash) && b.is_a?(Hash)
      return false unless a.length == b.length

      return a.all? { |k, v| b.key?(k) && same(v, b[k]) }
    end
    if a.is_a?(Array) || b.is_a?(Array)
      return false unless a.is_a?(Array) && b.is_a?(Array) && a.length == b.length

      return a.each_with_index.all? { |v, i| same(v, b[i]) }
    end
    a == b
  end

  # Partial match: every key the expectation names must agree, and keys
  # it does not name are ignored. `__EXISTS__` asserts presence without
  # pinning a value; `/re/` matches a string as a regular expression.
  def self.matches(expect, actual)
    return !MISSING.equal?(actual) && !actual.nil? if expect == '__EXISTS__'
    return MISSING.equal?(actual) if expect == '__UNDEF__'
    return !MISSING.equal?(actual) && actual.nil? if expect == '__NULL__'

    actual = nil if MISSING.equal?(actual)

    if expect.is_a?(String) && expect.length > 2 &&
       expect.start_with?('/') && expect.end_with?('/')
      return false unless actual.is_a?(String)

      return !Regexp.new(expect[1..-2]).match(actual).nil?
    end

    if expect.is_a?(Array)
      return false unless actual.is_a?(Array) && expect.length == actual.length

      return expect.each_with_index.all? { |v, i| matches(v, actual[i]) }
    end

    if expect.is_a?(Hash)
      return false unless actual.is_a?(Hash)

      return expect.all? do |k, v|
        matches(v, actual.key?(k) ? actual[k] : MISSING)
      end
    end

    expect == actual
  end

  # Run one entry against a subject and report the disagreement, if any.
  #
  # The three combinations the spec format allows are enforced here as
  # well as at build time, because a runner that quietly accepted `err`
  # beside `out` would let a contradictory entry pass.
  def self.check(entry)
    return 'entry has both err and out' if entry.key?('err') && entry.key?('out')

    value = nil
    raised = nil
    begin
      value = yield(entry)
    rescue StandardError => e
      raised = e
    end

    if entry.key?('err')
      return "expected a raise, got: #{JSON.generate(value)}" if raised.nil?

      if entry['err'] != true
        # Errors compare by CODE (section 12). Message wording is a
        # port's own business, and pinning it would make every
        # translation a corpus change.
        got = VoxgigPlugin.codeof(raised)
        if got != entry['err']
          return "expected code #{entry['err']}, got #{got} (#{raised.message})"
        end
      end
      if entry.key?('match')
        got = { 'err' => { 'code' => VoxgigPlugin.codeof(raised),
                           'message' => raised.message,
                           'name' => 'PluginError' } }
        unless matches(entry['match'], got)
          return "error did not match #{JSON.generate(entry['match'])}, " \
                 "got #{JSON.generate(got)}"
        end
      end
      return nil
    end

    unless raised.nil?
      return "unexpected raise: #{VoxgigPlugin.codeof(raised)} #{raised.message}"
    end

    if entry.key?('out') && !same(entry['out'], value)
      return "expected #{JSON.generate(entry['out'])}, got #{JSON.generate(value)}"
    end

    if entry.key?('match')
      got = { 'in' => entry['in'], 'out' => value }
      unless matches(entry['match'], got)
        return "did not match #{JSON.generate(entry['match'])}, " \
               "got out=#{JSON.generate(value)}"
      end
    end

    return 'entry asserts nothing' if !entry.key?('out') && !entry.key?('match')

    nil
  end
end
