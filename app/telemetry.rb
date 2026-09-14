# frozen_string_literal: true

# 演示用埋点：框架 v1 没有可观测性入口（信号依赖图 / Effect 重跑 / 渲染开销），
# 这里用最小侵入的方式自己接一套计数器。浏览器侧只有 DOM 计数需要注入
# （见 browser_glue.rb）；Effect#run 的计数是纯 Ruby，直接包装即可。
#
# 注意：这是踩坑记录里的"框架缺口"，不是推荐做法——理想形态是框架内置
# `Citrine.telemetry` / DevTools 钩子（GOALS.md P1-8）。
require "citrine"

module Citrine
  module Telemetry
    class << self
      attr_accessor :round_effect_runs, :round_node_creates,
                    :last_effect_runs, :last_node_creates, :last_elapsed_ms,
                    :total_effect_runs, :total_node_creates, :rounds

      def install!
        install_effect_counter!
        self.round_effect_runs ||= 0
        self.round_node_creates ||= 0
        self.last_effect_runs ||= 0
        self.last_node_creates ||= 0
        self.last_elapsed_ms ||= 0
        self.total_effect_runs ||= 0
        self.total_node_creates ||= 0
        self.rounds ||= 0
        true
      end

      def reset_round!
        self.round_effect_runs = 0
        self.round_node_creates = 0
      end

      def count_effect
        self.round_effect_runs = round_effect_runs.to_i + 1
      end

      def count_node
        self.round_node_creates = round_node_creates.to_i + 1
      end

      # 一轮 tick 结束：把本轮计数搬到 last_*，并累计总量
      def snapshot!(elapsed_ms = 0)
        self.last_effect_runs = round_effect_runs.to_i
        self.last_node_creates = round_node_creates.to_i
        self.last_elapsed_ms = elapsed_ms.to_i
        self.total_effect_runs = total_effect_runs.to_i + round_effect_runs.to_i
        self.total_node_creates = total_node_creates.to_i + round_node_creates.to_i
        self.rounds = rounds.to_i + 1
        report
      end

      def report
        {
          effect_runs: last_effect_runs.to_i,
          node_creates: last_node_creates.to_i,
          elapsed_ms: last_elapsed_ms.to_i,
          total_effect_runs: total_effect_runs.to_i,
          total_node_creates: total_node_creates.to_i,
          rounds: rounds.to_i
        }
      end

      private

      def install_effect_counter!
        return if Citrine::Effect.method_defined?(:run_with_telemetry)

        Citrine::Effect.class_eval do
          alias_method :run_without_telemetry, :run
          define_method(:run) do
            Citrine::Telemetry.count_effect
            run_without_telemetry
          end
        end
      end
    end
  end
end
