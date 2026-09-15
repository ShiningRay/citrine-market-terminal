# frozen_string_literal: true

# 一次跑完 native 的全部测试（不需要窗口、不需要 libui）：
#
#   ruby native/test/run.rb
require_relative "test_helper"

Dir[File.join(__dir__, "*_test.rb")].sort.each { |file| require file }
