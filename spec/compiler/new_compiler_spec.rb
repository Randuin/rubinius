require File.dirname(__FILE__) + '/spec_helper'
require File.dirname(__FILE__) + '/../spec_helper'

alias :old_description :description
def description name = nil
  tg = TestGenerator.new
  yield tg
  s(:method_description, *Sexp.from_array(tg.stream))
end

require File.dirname(__FILE__) + '/compiler_test'

Object.send :remove_const, :Compiler

class Symbol
  alias :old_eq2 :==
  def == o
    case o
    when TestGenerator::Label
      old_eq2 o.to_sym
    else
      old_eq2 o
    end
  end
end

class Compiler < SexpProcessor
  def initialize
    super
    self.auto_shift_type = true
    self.strict = false

    @slots = {}
    @current_slot = -1
    @jump = @literal = 0
  end

  def process exp
    exp = super exp

    exp = strip_dummies exp

    if exp.first == :dummy then
      exp[0] = :test_generator
    else
      exp = s(:test_generator, exp)
    end if self.context.empty?

    exp
  end

  def process_and exp
    result = s(:dummy)

    fixme = [] # TODO: see angry note in process_or

    until exp.empty? do
      result << process(exp.shift)
      result << s(:dup)
      result << s(:gif)
      fixme  << result.last
      result << s(:pop)
    end
    3.times { result.pop }

    bottom = new_jump
    fixme.each { |s| s << bottom }
    result << s(:set_label, bottom)

    result
  end

  ##
  # Invented node type is an if w/o an else body, allowing us to use
  # this internally for several different forms.

  def process_s_if exp
    c = process(exp.shift)
    flip = exp.pop if exp.last == true
    t = process(s(:dummy, *exp))
    j = flip ? :gif : :git

    exp.clear # appease the sexp processor gods

    j2 = s(j, new_jump)
    s2 = s(:set_label, j2.last)

    s(:dummy, c, j2, t, s2)
  end

  def process_args exp
    result = s(:dummy)

    @slots.clear
    block_arg = nil
    opt_args = exp.block(true)

    until exp.empty? do
      arg = exp.shift
      slot = new_slot

      case arg.to_s
      when /^\*(.*)/ then
        next if $1.empty?
        arg = $1.to_sym
      when /^\&(.+)/ then
        arg = $1.to_sym
        block_arg = slot
      end

      @slots[arg] = slot
    end

    if opt_args then
      opt_args.map! { |opt_arg|
        next opt_arg if Symbol === opt_arg
        name, val = opt_arg[1..2]
        s(:s_if, s(:passed_arg, name2slot(name)),
          s(:lasgn, name, val),
          s(:pop))
      }

      opt_args[0] = :dummy
      result[1, 0] = process(opt_args)[1..-1]
    end

    if block_arg then
      result << s(:push_block) << s(:dup)
      result << process(s(:s_if, s(:is_nil),
                          s(:push_const, :Proc),
                          s(:swap),
                          s(:send, :__from_block__, 1)))
      result << s(:set_local, slot) << s(:pop)
    end

    result
  end

  def process_array exp
    result = s(:dummy)

    until exp.empty? do
      result << process(exp.shift)
    end

    result << s(:make_array, result.size - 1)

    result
  end

  def process_block exp
    return rewrite(s(:nil)) if exp.empty?

    result = s(:dummy)

    until exp.empty? do
      result << process(exp.shift)
      result << s(:pop)
    end

    result.pop if result.size > 2 # remove last pop

    result
  end

  def process_arglist exp
    result = s(:dummy)
    until exp.empty? do
      result << process(exp.shift)
    end
    result
  end

  def process_block_pass exp
    block    = exp.shift
    call     = exp.shift
    recv     = call.delete_at(1)
    args     = call.pop
    arity    = args.size - 1

    call[0] = :send_with_block
    call << arity
    call << !recv

    s(:dummy,
      process(recv || s(:push, :self)),
      process(args),
      process(block),
      s(:dup),
      process(s(:s_if, s(:is_nil),
                s(:push_cpath_top),
                s(:find_const, :Proc),
                s(:swap),
                s(:send, :__from_block__, 1))),
      call)
  end

  def process_call exp
    recv  = process(exp.shift)
    mesg  = exp.shift
    args  = exp.shift
    arity = args.size - 1

    args[0] = :dummy
    args  = process(args)

    private_send = recv.nil?
    recv = s(:push, :self) if private_send

    case mesg    # TODO: this sucks... we shouldn't do this analysis here
    when :+ then
      s(:dummy, recv, args, s(:meta_send_op_plus))
    else
      s(:dummy, recv, args, s(:send, mesg, arity, private_send))
    end
  end

  def process_colon2 exp
    s(:dummy,
      exp.shift,
      s(:find_const, exp.shift))
  end

  def process_colon3 exp
    s(:dummy,
      s(:push_cpath_top),
      s(:find_const, exp.shift))
  end

  def defn_or_defs exp, type
    recv = process(exp.shift) if type == :defs
    name = exp.shift
    args = process(exp.shift)
    body = process(exp.shift)
    msg  = type == :defs ? :attach_method : :__add_method__

    body[0] = :method_description
    body[1, 0] = args[1..-1] # HACK: fucking fix dummy!
    body << s(:ret)

    s(:dummy,
      (recv if type == :defs),
      type == :defn ? s(:push_context) : s(:send, :metaclass, 0),
      s(:push_literal, name),
      s(:push_literal, body),
      s(:send, msg, 2)).compact
  end

  def process_defn exp
    defn_or_defs exp, :defn
  end

  def process_defs exp
    defn_or_defs exp, :defs
  end

  def process_dregx exp
    options = Fixnum === exp.last ? exp.pop : 0

    s(:dummy,
      s(:push_const, :Regexp),
      *process_dstr(exp)[1..-1]) << s(:push, options) << s(:send, :new, 2)
  end

  def process_dstr exp
    result = s(:dummy)

    size = exp.size

    until exp.empty? do
      part = exp.pop # going from the back
      case part
      when String
        result << s(:push_literal, part)
        result << s(:string_dup)
      else
        result << process(part)
      end
    end

    (size-1).times do
      result << s(:string_append)
    end

    result
  end

  def process_evstr exp
    s(:dummy, process(exp.shift), s(:send, :to_s, 0, true))
  end

  def process_if exp
    c = process(exp.shift)
    t = process(exp.shift)
    f = process(exp.shift)
    j = :gif

    t, f, j = f, t, :git if t.nil?

    t ||= s(:push, :nil)
    f ||= s(:push, :nil)

    j2 = s(j,          new_jump)
    j3 = s(:goto,      new_jump)
    s2 = s(:set_label, j2.last)
    s3 = s(:set_label, j3.last)

    s(:dummy, c, j2, t, j3, s2, f, s3).compact
  end

  def process_lasgn exp
    lhs = exp.shift # TODO: register name to slot
    rhs = process(exp.shift)

    idx = name2slot lhs, false

    s(:dummy, rhs, s(:set_local, idx))
  end

  def process_lit exp # TODO: rewriter
    val = exp.shift

    case val
    when Float, Integer then
      s(:push, val)
    when Range then
      if val.exclude_end? then
        rewrite_dot3(s(:dot3, s(:push, val.begin), s(:push, val.end)))
      else
        rewrite_dot2(s(:dot2, s(:push, val.begin), s(:push, val.end)))
      end
    when Symbol then
      s(:push_unique_literal, val)
    when Regexp then
      literal = new_literal

      s(:dummy,
        s(:add_literal, nil), # TODO: possibly rewrite this as s(:cache, o)
        s(:push_literal_at, literal),
        s(:dup),
        process(s(:s_if, s(:is_nil), # TODO: flip to rewrite and process goes
                  s(:pop),
                  s(:push_const, :Regexp),
                  s(:push_literal, val.source),
                  s(:push, val.options),
                  s(:send, :new, 2),
                  s(:set_literal, literal),
                  true)))
    else
      raise "not yet"
    end
  end

  def process_lvar exp
    lhs = exp.shift
    idx = name2slot lhs

    s(:push_local, idx)
  end

  def process_or exp
    result = s(:dummy)

    fixme = [] # TODO: see note below

    until exp.empty? do
      result << process(exp.shift)
      result << s(:dup)
      result << s(:git)
      fixme  << result.last
      result << s(:pop)
    end
    3.times { result.pop }

    # TODO: this is just to delay the creation of the labels so I can
    # TODO: pass the specs with the old way of generating labels (at
    # TODO: set_label... there is NO NEED FOR IT OTHERWISE, and is
    # TODO: cleaner without. So once the tests pass, remove this.
    bottom = new_jump
    fixme.each { |s| s << bottom }

    result << s(:set_label, bottom)

    result
  end

  def process_return exp
    val = process(exp.shift) || s(:push, :nil)

    s(:dummy, val, s(:ret))
  end

  def process_undef exp
    name = exp.shift.last
    s(:dummy,
      s(:push, :self),
      s(:send, :metaclass, 0),
      s(:push_literal, name),
      s(:send, :undef_method, 1))
  end

  def process_until exp
    while_or_until exp, :git
  end

  def process_while exp
    while_or_until exp, :gif
  end

  def process_yield exp
    empty  = exp.empty?
    result = s(:dummy, s(:push_block))

    until exp.empty? do
      result << process(exp.shift)
    end

    result << s(:meta_send_call, empty ? 0 : 1)

    result
  end

  ############################################################
  # Rewrites

  def rewrite_alias exp
    exp[1][0] = exp[2][0] = :push_literal # TODO: this is horridly inconsistent

    s(:dummy,
      s(:push_context),
      exp[1],
      exp[2],
      s(:send, :alias_method, 2, true))
  end

  def rewrite_back_ref exp
    s(:dummy,
      s(:push_context),
      s(:push_literal, exp.last),
      s(:send, :back_ref, 1))
  end

  def rewrite_cdecl exp
    cdecl_or_cvdecl exp, s(:push_context), :__const_set__
  end

  def rewrite_class exp
    class_or_module exp, :class
  end

  def rewrite_const exp
    exp[0] = :push_const
    exp
  end

  def rewrite_cvar exp
    s(:dummy,
      s(:push_context),
      s(:push_literal, exp[1]),
      s(:send, :class_variable_get, 1))
  end

  def rewrite_cvdecl exp
    cdecl_or_cvdecl exp, s(:push, :self), :class_variable_set
  end
  alias :rewrite_cvasgn :rewrite_cvdecl

  def rewrite_dot2 exp
    s(:dummy,
      s(:push_cpath_top),
      s(:find_const, :Range),
      exp[1],
      exp[2],
      s(:send, :new, 2))
  end

  def rewrite_dot3 exp
    s(:dummy,
      s(:push_cpath_top),
      s(:find_const, :Range),
      exp[1],
      exp[2],
      s(:push, :true),
      s(:send, :new, 3))
  end

  def rewrite_false exp
    s(:push, :false)
  end

  def rewrite_gasgn exp
    s(:dummy,
      s(:push_cpath_top),
      s(:find_const, :Globals),
      s(:push_literal, exp[1]),
      exp[2],
      s(:send, :[]=, 2))
  end

  def rewrite_gvar exp
    s(:dummy,
      s(:push_cpath_top),
      s(:find_const, :Globals),
      s(:push_literal, exp.last),
      s(:send, :[], 1))
  end

  def rewrite_hash exp
    exp[0] = :dummy
    s(:dummy,
      s(:push_cpath_top),
      s(:find_const, :Hash),
      exp,
      s(:send, :[], exp.size - 1))
  end

  def rewrite_iasgn exp
    s(:dummy,
      exp[2],
      s(:set_ivar, exp[1]))
  end

  def rewrite_ivar exp
    s(:push_ivar, exp[1])
  end

  def rewrite_module exp
    class_or_module exp, :module
  end

  def rewrite_nil exp
    s(:push, :nil)
  end

  def rewrite_scope exp
    exp[0] = :dummy
    exp
  end

  def rewrite_self exp
    s(:push, :self)
  end

  def rewrite_str exp
    s(:dummy,
      s(:push_literal, exp[1]),
      s(:string_dup))
  end

  def rewrite_true exp
    s(:push, :true)
  end

  def rewrite_valias exp
    s(:dummy,
      s(:push_cpath_top),
      s(:find_const, :Globals),
      s(:push_literal, exp[2]),
      s(:push_literal, exp[1]),
      s(:send, :add_alias, 2))
  end

  def rewrite_xstr exp
    s(:dummy,
      s(:push, :self),
      s(:push_literal, exp[1]),
      s(:string_dup),
      s(:send, :"`", 1, true))
  end

  ############################################################
  # Helpers

  def cdecl_or_cvdecl exp, recv, mesg
    lhs = exp[1]
    rhs = exp[2]

    if Symbol === lhs then
      lhs = s(:dummy, recv, s(:push_literal, lhs))
    else
      lhs.last[0] = :push_literal
    end

    s(:dummy, lhs, rhs, s(:send, mesg, 2))
  end

  def class_or_module exp, type
    _ = exp.shift # type
    name = exp.shift
    supr = exp.shift || s(:push, :nil) if type == :class
    body = exp.shift

    name = case name
           when Symbol then
             s(:"open_#{type}", name)
           when Sexp then
             case name.first
             when :colon2 then
               s, supr = supr, nil
               s(:dummy, name[1], s,
                 s(:"open_#{type}_under", name.last)).compact
             when :colon3 then
               s(:"open_#{type}", name.last)
             else
               raise "no? #{name.inspect}"
             end
           else
             raise "no? #{name.inspect}"
           end

    result = s(:dummy,
               supr,
               name).compact

    if body != s(:dummy) then # TODO: this seems icky
      result.push(s(:dup),
                  s(:push_literal,
                    s(:method_description,
                      s(:push_self), # FIX: ARGH!
                      s(:add_scope),
                      body,
                      s(:ret))),
                  s(:swap),
                  s(:attach_method, :"__#{type}_init__"),
                  s(:pop),
                  s(:send, :"__#{type}_init__", 0))
    end

    result
  end

  # TODO: move to name2index sexp processor phase
  def name2slot name, raise_if_missing = true
    idx = @slots[name]
    if raise_if_missing then
      raise "unknown var name #{name.inspect} in #{@slots.inspect}" unless idx
    else
      idx = @slots[name] = new_slot
    end unless idx
    idx
  end

  def new_jump
    @jump += 1
    :"label_#{@jump}"
  end

  def new_literal # FIX: this is gonna break. original based on @ip, not incr
    @literal += 1
    @literal
  end

  def new_slot
    @current_slot += 1
    @current_slot
  end

  def strip_dummies exp # TODO: build this in
    return if exp.nil?

    result = s(exp.shift)

    until exp.empty? do
      v = exp.shift

      if Sexp === v then
        if v.first == :dummy then
          result.push(*v[1..-1].map { |o| strip_dummies(o) })
        else
          result.push(Sexp.from_array(v.map { |o|
                                        Sexp === o ? strip_dummies(o) : o
                                      }))
        end
      else
        result << v
      end
    end
    result
  end

  def while_or_until exp, jump
    cond = exp.shift
    body = exp.shift
    pre  = exp.shift

    jump_top   = new_jump
    jump_dunno = new_jump
    jump_f     = new_jump
    jump_bot   = new_jump

    result = s(:dummy)
    result << s(:push_modifiers)
    result << s(:set_label, jump_top)

    if pre then
      result << process(cond)
      result << s(jump, jump_f)
      result << s(:set_label, jump_dunno)
    end

    result << (process(body) || s(:push, :nil)) # TODO: ewww
    result << s(:pop)

    unless pre then
      result << s(:set_label, jump_dunno)
      result << process(cond)
      result << s(jump, jump_f)
    end

    result << s(:goto, jump_top)
    result << s(:set_label, jump_f)
    result << s(:push, :nil)
    result << s(:set_label, jump_bot)
    result << s(:pop_modifiers)

    result
  end
end

describe "Compiler::*Nodes" do
  ParseTreeTestCase.testcases.sort.each do |node, hash|
    next if Array === hash['Ruby']
    next if hash['Compiler'] == :skip

    it "compiles :#{node}" do
      input    = hash['Ruby']
      expected = hash['Compiler']

      input.should_not == nil
      expected.should_not == nil

      sexp   = Sexp.from_array input.to_sexp("(eval)", 1, false)
      comp   = ::Compiler.new
      node   = comp.process sexp

      expected = s(:test_generator, *Sexp.from_array(expected.stream))

      node.should == expected
    end
  end
end

# class Environment
#   attr_reader :env

#   def initialize
#     @env = []
#     @env.unshift({})
#   end

#   def all
#     @env.reverse.inject { |env, scope| env.merge scope }
#   end

#   def current
#     @env.first
#   end

#   def depth
#     @env.length
#   end

#   def [] name
#     self._get(name)
#   end

#   def []= name, val
#     self._get(name) = val
#   end

#   def scope
#     @env.unshift({})
#     begin
#       yield
#     ensure
#       @env.shift
#       raise "You went too far unextending env" if @env.empty?
#     end
#   end

#   def _get(name)
#     @env.each do |closure|
#       return closure[name] if closure.has_key? name
#     end

#     raise NameError, "Unbound var: #{name.inspect} in #{@env.inspect}"
#   end
# end
