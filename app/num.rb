# frozen_string_literal: true

# 跨平台数值工具——**已迁移到框架实现**（FRICTION.md F12/F13 → 框架侧 Citrine::Num）。
#
# 从前这里有一份 `idiv` / `round_to` / `round0/1/2` 的手写实现，与姊妹仓库
# citrine-sheets 里那份同构——"每个应用都要写一遍"正是这条摩擦的论据。
# 现在框架提供 `Citrine::Num`（`lib/citrine/num.rb`，并自带 CRuby/Opal 语义测试），
# 本文件只保留常量别名，让调用点继续用短名字；应用侧那份实现已删除。
require "citrine"

module Market
  Num = Citrine::Num
end
