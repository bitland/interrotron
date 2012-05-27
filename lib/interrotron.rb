require "interrotron/version"
require 'date'
require 'hashie/mash'
require 'yaml'
require 'debugger'

# This is a Lispish DSL meant to define business rules
# in environments where you do *not* want a turing complete language.
# It comes with a very small number of builtin functions, all overridable.
#
# It is meant to aid in creating a DSL that can be executed in environments
# where code injection could be dangerous.
#
# To compile and run, you could, for example:
#     Interrotron.new().compile('(+ a_custom_var 2)').call("a_custom_var" => 4)
#     Interrotron.new().compile.run('(+ a_custom_var 4)', :vars => {"a_custom_var" => 2})
#     => 6
# You can inject your own custom functions and constants via the :vars option.
#
# Additionally, you can cap the number of operations exected with the :max_ops option
# This is of limited value since recursion is not a feature
#
class Interrotron
  class ParserError < StandardError; end
  class InvalidTokenError < ParserError; end
  class SyntaxError < ParserError; end
  class UndefinedVarError < ParserError; end
  class OpsThresholdError < StandardError; end
  class InterroArgumentError < StandardError; end

  class Macro
    def initialize(&block)
      @block = block
    end
    def call(*args)
      @block.call(*args)
    end
  end

  class Token
    attr_accessor :type, :value
    def initialize(type,value)
      @type = type
      @value = value
    end
  end
  
  TOKENS = [
            [:lpar, /\(/],
            [:rpar, /\)/],
            [:fn, /fn/],
            [:var, /[A-Za-z_><\+\>\<\!\=\*\/\%\-]+/],
            [:num, /(\-?[0-9]+(\.[0-9]+)?)/],
            [:datetime, /#dt\{([^\{]+)\}/, {capture: 1}],
            [:spc, /\s+/, {discard: true}],
            [:str, /"([^"\\]*(\\.[^"\\]*)*)"/, {capture: 1}],
            [:str, /'([^'\\]*(\\.[^'\\]*)*)'/, {capture: 1}]
           ]

  # Quote a ruby variable as a interrotron one
  def self.qvar(val)
    Token.new(:var, val.to_s)
  end

  DEFAULT_VARS = Hashie::Mash.new({
    'if' => Macro.new {|i,pred,t_clause,f_clause| i.vm_eval(pred) ? t_clause : f_clause },
    'cond' => Macro.new {|i,*args|
                 raise InterroArgumentError, "Cond requires at least 3 args" unless args.length >= 3
                 raise InterroArgumentError, "Cond requires an even # of args!" unless args.length.even?
                 res = qvar('nil')
                 args.each_slice(2).any? {|slice|
                   pred, expr = slice
                   res = expr if i.vm_eval(pred)
                 }
                 res
    },
    'and' => Macro.new {|i,*args| args.all? {|a| i.vm_eval(a)} ? args.last : qvar('false')  },
    'or' => Macro.new {|i,*args| args.detect {|a| i.vm_eval(a) } || qvar('false') },
    'array' => proc {|*args| args},
    'identity' => proc {|a| a},
    'not' => proc {|a| !a},
    '!' => proc {|a| !a},
    '>' => proc {|a,b| a > b},
    '<' => proc {|a,b| a < b},
    '>=' => proc {|a,b| a >= b},
    '<=' => proc {|a,b| a <= b},
    '='  => proc {|a,b| a == b},
    '!=' => proc {|a,b| a != b},
    'true' => true,
    'false' => false,
    'nil' => nil,
    '+' => proc {|*args| args.reduce(&:+)},
    '-' => proc {|*args| args.reduce(&:-)},
    '*' => proc {|*args| args.reduce(&:*)},
    '/' => proc {|a,b| a / b},
    '%' => proc {|a,b| a % b},
    'floor' =>  proc {|a| a.floor},
    'ceil' => proc {|a| a.ceil},
    'round' => proc {|a| a.round},
    'max' => proc {|arr| arr.max},
    'min' => proc {|arr| arr.min},
    'first' => proc {|arr| arr.first},
    'last' => proc {|arr| arr.last},
    'length' => proc {|arr| arr.length},
    'to_i' => proc {|a| a.to_i},
    'to_f' => proc {|a| a.to_f},
    'rand' => proc { rand },
    'upcase' => proc {|a| a.upcase},
    'downcase' => proc {|a| a.downcase},
    'now' => proc { DateTime.now },
    'str' => proc {|*args| args.reduce("") {|m,a| m + a.to_s}}
  })

  def initialize(vars={},max_ops=nil)
    @max_ops = max_ops
    @instance_default_vars = DEFAULT_VARS.merge(vars)
    @stack = [@instance_default_vars]
  end
  
  def lex(str)
    return [] if str.nil?
    tokens = []
    while str.length > 0
      matched_any = TOKENS.any? {|name,matcher,opts|
        opts ||= {}
        matches = matcher.match(str)
        if !matches || !matches.pre_match.empty?
          false
        else
          mlen = matches[0].length
          str = str[mlen..-1]
          m = matches[opts[:capture] || 0]
          tokens << Token.new(name, m) unless opts[:discard] == true
          true
        end
      }
      raise InvalidTokenError, "Invalid token at: #{str}" unless matched_any
    end
    tokens
  end
  
  # Transforms token values to ruby types
  def cast(t)
    new_val = case t.type
              when :num
                t.value =~ /\./ ? t.value.to_f : t.value.to_i
              when :datetime
                DateTime.parse(t.value)
              else
                t.value
              end
    t.value = new_val
    t
  end
  
  def parse(tokens)
    return [] if tokens.empty?
    expr = []
    t = tokens.shift
    if t.type == :lpar
      while t = tokens[0]
        if t.type == :lpar
          expr << parse(tokens)
        else
          tokens.shift
          break if t.type == :rpar
          expr << cast(t)
        end
      end
    elsif t.type != :rpar
      tokens.shift
      expr << cast(t)
      #raise SyntaxError, "Expected :lparen, got #{t} while parsing #{tokens}"
    end
    expr
  end
  
  def resolve_token(token)
    case token.type
    when :var
      frame = @stack.reverse.find {|frame| frame.has_key?(token.value) }
      raise UndefinedVarError, "Var '#{token.value}' is undefined!" unless frame
      frame[token.value]
    else
      token.value
    end
  end

  def fn
    
  end
  
  def vm_eval(expr,max_ops=nil,ops_cnt=0)
    return resolve_token(expr) if expr.is_a?(Token)
    return nil if expr.empty?
    raise OpsThresholdError, "Exceeded max ops(#{max_ops}) allowed!" if max_ops && ops_cnt > max_ops

    head = vm_eval(expr[0])
    if head.is_a?(Macro)
      expanded = head.call(self, *expr[1..-1])
      vm_eval(expanded)
    else
      args = expr[1..-1].map {|e|vm_eval(e)}

      head.is_a?(Proc) ? head.call(*args) : head
    end
  end

  # Returns a Proc than can be executed with #call
  # Use if you want to repeatedly execute one script, this
  # Will only lex/parse once
  def compile(str)
    tokens = lex(str)
    ast = parse(tokens)

    proc {|vars| 
      @stack = [@instance_default_vars.merge(vars)]
      vm_eval(ast)
    }
  end

  def self.compile(str)
    Interrotron.new().compile(str)
  end

  def run(str,vars={})
    compile(str).call(vars)
  end

  def self.run(str,vars={})
    Interrotron.new().run(str,vars)
  end
end
