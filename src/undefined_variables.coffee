vars = require './vars.js'

mandatoryEnvironments = [ 'ecmaIdentifiers', 'reservedVars' ]
module.exports = class

    rule:
        name: 'undefined_variables'

        # This isn't REALLY configurable, I just want to be clear that hoisted
        # variables are considered an error.
        allowHoisting: false
        level : 'error'
        message : 'Undefinded variable'
        description : 'Detect undefined variables'
        environments: do ->
            cfg = {}
            cfg[env] = false for env of vars

            delete cfg[env] for env in mandatoryEnvironments
            cfg

        globals: []

    lintAST : (node, @astApi) ->
        @depth = 0
        @scopes = []
        @newScope()

        @setupVariables()
        if @astApi.config[@rule.name].allowHoisting
            # You're welcome to implement allowHoisting if you like. I don't
            # think it makes any sense when reading a file to have to read a
            # complete outer scope before being able to understand an inner
            # scope. I don't think anyone would like if I stored this message
            # in the last line of this file then use it here, it only make the
            # code difficult to read.
            throw new Error "allowHoisting hasn't been implemented"

        node.eachChild @lintNode

        @popScope()

        # If this ever happens it indicates something is wrong in the code.
        # Probably not something a user could ever trigger.
        if @scopes.length isnt 0
            throw new Error "Error walking AST for undefined_variables"
        undefined

    setupVariables: ->
        ruleConfig = @astApi.config[@rule.name]
        for v in ruleConfig.globals
            @currentScope[v] = { defined: -1, used: true }

        defineAll = (key) =>
            throw new Error "Invalid environment #{key}" unless vars[key]?
            for v of vars[key]
                @currentScope[v] = { defined: -1, used: true }

        # `this` is really a keyword, but it shows up as a variable.
        # Simulating a global `this` is good enough for undefined/unused
        # variable detection.
        vars.reservedVars.this = true

        defineAll env for env in mandatoryEnvironments

        if ruleConfig.environments.shelljs
            ruleConfig.environments.node = true

        if ruleConfig.environments.node or ruleConfig.environments.browser
            ruleConfig.environments.typed = true

        for env, value of ruleConfig.environments when value
            defineAll env

    newScope: ->
        parentScope = @currentScope

        Scope = ->
        if parentScope?
            Scope.prototype = parentScope

        cs = new Scope
        @scopes.push cs
        @currentScope = cs
        console.assert @currentScope in @scopes, 'foo'
        undefined

    newVariable: (variable, options = {}) ->
        return unless variable?
        base = variable.base
        name = base.value


        # Assigning a property to an object. This needs to verify that
        # the object exists.
        if variable.properties?.length > 0
            # Catch assigning a property to an undefined variable
            @checkExists variable.base

            # Make sure array style access is using defined variables
            for index, p of variable.properties
                if p.index?
                    @checkExists p.index.base
            return

        if name?
            unless @currentScope[name]?
                options.defined = base.locationData.first_line + 1
                options.used = false
                @currentScope[name] = options

    popScope: ->
        exitingScope = @scopes.pop()
        @currentScope = @scopes[@scopes.length - 1]
        for own name, data of exitingScope
            unless data.used

                # When iterating over an object you must define a variable for
                # the index even if you only need the values. Similarly you
                # might define multiple parameters in a function when only
                # needing the last one.
                #
                # dependsOn allows an exception in these cases where if you
                # defined an index for the loop then using the value is
                # sufficient to avoid an unused variable error.
                current = data
                while current? and current.used is false
                    current = exitingScope[current.dependsOn]

                unless current?.used
                    @errors.push @astApi.createError {
                        context: name
                        message : 'Unused variable'
                        lineNumber: data.defined
                    }

        undefined

    checkExists: (base) ->
        value = base?.value

        # Literal values like strings and integers aren't assignable but get
        # passed through here when used as arguments for a function.  A falsy
        # check won't work with ?(), it needs to be false.
        if not base? or base?.isAssignable?() is false
            return true

        if value? and @currentScope[value]?
            @currentScope[value].used = true
        else if value?
            @errors.push @astApi.createError {
                context: value
                message : 'Undefined variable'
                lineNumber: base.locationData.first_line + 1
            }
            return false
        true


    # This only needs to be called from lintAST and lintChildren.
    lintNode: (node) =>

        # Get the complexity of the current node.
        name = node.constructor.name

        # Sets errorVariable from Try node for second block
        if name is 'Block' && @forceCatchVars[@level]?
            if @forceCatchVars[@level].blocks == 1
                @newVariable @forceCatchVars[@level].variable
                @forceCatchVars[@level] = null
            else
                @forceCatchVars[@level].blocks++

        switch name
            when 'Assign' then @lintAssign node
            # when 'Block' then @lintBlock node
            # when 'Call' then @lintCall node
            when 'Class' then @newVariable node.variable
            when 'Code' then @lintCode node
            when 'Comment' then @lintComment node
            when 'Existence' then @lintExistence node
            when 'For' then @lintFor node
            when 'If' then @lintIf node
            when 'In' then @lintIn node
            when 'Op' then @lintOp node
            when 'Splat' then @checkExists node.name.base
            when 'Try' then @lintTry node
            when 'Value' then @lintValue node

        @lintChildren(node)

        # Return needs to go depth first.
        if name is 'Return'
            # TODO: Figure out the right patterns, right now this is all just
            # guessing
            if node.expression?
                @checkExists node.expression.variable?.base
                @checkExists node.expression
                @checkExists node.expressionbase

        else if name is 'Code'
            @popScope()

        undefined

    lintValue: (node) ->
        @checkExists node.base

    lintAssign: ( { variable, value } ) ->
        # The isAssignable check will prevent processing strings:
        # { "key": "value" }
        # The above is an assignement, but `key` is not assignable.
        if variable.base.isAssignable() and variable.properties.length is 0 and
                # I don't know what else this could be, but CoffeeScript checks
                # to see if it's an instanceof Value in compileNode().
                variable.constructor.name is 'Value'
            @newVariable variable

        if variable.isObject()
            @destructureObject variable
        if variable.isArray()
            @destructureArray variable


    destructure: (node) ->
        if node.base.constructor.name is 'Arr'
            @destructureArray node
        else
            @destructureObject node

    # {
    #     a
    #     b: { c }
    # } = foo
    destructureObject: (node) ->
        if node.base.isAssignable()
            return @newVariable node

        node.base.properties.forEach (p) =>
            # Handle `a`
            if p.isAssignable()
                @newVariable p
            # b: { c }
            # is an assignment. b is the `variable` and
            # { c } is the `value`
            else if p.constructor.name is 'Assign'
                @destructure p.value

    destructureArray: (node) ->
        node.base.objects.forEach (o) =>
            if o.isAssignable()
                if o.constructor.name is 'Splat'
                    @newVariable o.name
                else
                    @newVariable o
            else if o.constructor.name is 'Expansion'
                # The `...` is an expansion. Nothing needs to be done.
                # [ first, ..., last ]
                undefined
            else
                @destructure o

    lintTry: (node) ->
        if node.errorVariable?
            @forceCatchVars[@level + 1] = {
                variable: { base: node.errorVariable }
                blocks: 0 # blocks counter, the variable is for second block which is `catch`
            }

    lintBlock: (node) ->
        # IDK if I like this, it modifies the AST.
        # node.makeReturn()

        for exp in node.expressions
            # Assignment somewhere?

            if exp.variable? and exp.value?
                # @newVariable exp.variable
                undefined
            # Splats have a source attribute instead of a variable.
            else if exp.source?
                @newVariable exp.source

    lintCall: (node) ->
        if node.variable?
            @checkExists node.variable.base
        for arg in node.args
            @checkExists arg.base

    lintCode: (node) ->
        @newScope()
        lastParam = undefined
        for param in node.params by -1
            # Everything seems to have a variable with a `.base` and
            # potentially a `.properties`. Since params seem to lack a base
            # this will create that fake level to make them match
            # @newVariable calls everywhere else

            param.base = param.name
            if param.isComplex()
                @destructure param
            else
                @newVariable param,
                    dependsOn: lastParam

                lastParam = param.name.value

    lintComment: (node) ->
        # http://stackoverflow.com/a/3537914/35247
        # JS Regex doesn't support capturing all of a repeating group.
        commentRegex = ///
            global
            (?:      # non capturing
                \s
                [^\s]+
            )*
        ///g

        line = node.locationData.first_line + 1
        tmp = commentRegex.exec(node.comment)
        return unless tmp?
        for variable in tmp[0].split(' ')[1..]
            @currentScope[variable] = { defined: line, used: false }

    lintFor: (node) ->
        if node.name?
            @newVariable { base: node.name }

        if node.index?
            @newVariable { base: node.index },
                dependsOn: node.name?.value

        @checkExists node.source.base

    lintExistence: (node) ->
        if node.expression.constructor.name is 'Value'
            @checkExists node.expression.base

    lintIf: (node) ->
        if node.condition.expression?
            @checkExists node.condition.expression.base

        if node.condition.constructor.name is 'Value'
            @checkExists node.condition.base

    lintIn: (node) ->
        @checkExists node.object.base
        @checkExists node.array.base

    lintOp: (node) ->
        @checkExists node.first.base
        if node.second?
            @checkExists node.second.base

    level: 0

    forceCatchVars: []

    lintChildren: (node) ->
        @level++
        node.eachChild (childNode) =>
            @lintNode(childNode) if childNode
            true
        @level--

