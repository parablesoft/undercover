# frozen_string_literal: true

$LOAD_PATH << 'lib'
require 'imagen'
require 'rainbow'
require 'bigdecimal'
require 'forwardable'

require 'undercover/lcov_parser'
require 'undercover/result'
require 'undercover/cli'
require 'undercover/changeset'
require 'undercover/formatter'
require 'undercover/options'
require 'undercover/version'

module Undercover
  class Report
    extend Forwardable
    def_delegators :changeset, :validate

    attr_reader :changeset,
                :lcov,
                :results,
                :code_dir

    # Initializes a new Undercover::Report
    #
    # @param changeset [Undercover::Changeset]
    # @param opts [Undercover::Options]
    def initialize(changeset, opts)
      @opts = opts
      @relative_git_dir = File.expand_path("#{opts.git_dir}/..")
      @lcov = LcovParser.parse(File.open(opts.lcov), opts.path)
      @code_dir = opts.path
      @changeset = changeset.update
      @results = {}
    end

    def build
      each_result_arg do |filename, coverage, imagen_node|
        key = filename.gsub(/^\.\//, '')
        results[key] ||= []
        results[key] << Result.new(
          imagen_node, coverage, filename
        )
      end
      self
    end

    # TODO: this is experimental and might be incorrect!
    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    def build_warnings
      flagged_results = Set.new

      changeset.each_changed_line do |filepath, line_no|
        dist_from_line_no = lambda do |res|
          return BigDecimal::INFINITY if line_no < res.first_line

          res_lines = res.first_line..res.last_line
          return BigDecimal::INFINITY unless res_lines.cover?(line_no)

          line_no - res.first_line
        end
        dist_from_line_no_sorter = lambda do |res1, res2|
          dist_from_line_no[res1] <=> dist_from_line_no[res2]
        end
        next unless results[filepath]

        res = results[filepath].min(&dist_from_line_no_sorter)
        flagged_results << res if res&.uncovered?(line_no)
      end
      flagged_results
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

    def all_results
      results.values.flatten
    end

    def inspect
      "#<Undercover::Report:#{object_id} results: #{results.size}>"
    end
    alias to_s inspect

    private

    # TODO: should that start from changeset.file_paths?
    # this way we could report things that weren't even loaded in any spec,
    # so is this still good idea? (Rakefile, .gemspec etc)
    def each_result_arg
      match_all = ->(_) { true }
      changeset.file_paths.each do |relative_filename|
        next unless relative_filename.to_s.end_with?(".rb")
        path = case relative_filename
               when Pathname then relative_filename
               else
                 File.expand_path(relative_filename, @relative_git_dir)
               end

        root_ast = Imagen::Node::Root.new.build_from_file(path)
        next if root_ast.children.empty?

        coverage = lcov.source_files[path.to_s]

        root_ast.children[0].find_all(match_all).each do |node|
          yield(path.to_s, coverage, node)
        end
      end
    end
  end
end
