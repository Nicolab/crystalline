require "compiler/crystal/**"

module Crystal
  class Compiler
    property file_overrides : Hash(String, String)? = nil

    private def new_program(sources)
      program = previous_def
      program.file_overrides = @file_overrides
      program
    end
  end

  class Program < NonGenericModuleType
    property file_overrides : Hash(String, String)? = nil
  end

  class SemanticVisitor < Visitor
    def visit(node : Require)
      if expanded = node.expanded
        expanded.accept self
        return false
      end

      if inside_exp?
        node.raise "can't require dynamically"
      end

      location = node.location
      filename = node.string
      relative_to = location.try &.original_filename

      # Remember that the program depends on this require
      @program.record_require(filename, relative_to)

      filenames = @program.find_in_path(filename, relative_to)
      if filenames
        nodes = Array(ASTNode).new(filenames.size)
        filenames.each do |filename|
          if @program.requires.add?(filename)
            file_contents = @program.file_overrides.try(&.[filename]?) || File.read(filename)
            parser = Parser.new file_contents, @program.string_pool
            parser.filename = filename
            parser.wants_doc = @program.wants_doc?
            parsed_nodes = parser.parse
            parsed_nodes = @program.normalize(parsed_nodes, inside_exp: inside_exp?)
            # We must type the node immediately, in case a file requires another
            # *before* one of the files in `filenames`
            parsed_nodes.accept self
            nodes << FileNode.new(parsed_nodes, filename)
          end
        end
        expanded = Expressions.from(nodes)
      else
        expanded = Nop.new
      end

      node.expanded = expanded
      node.bind_to(expanded)
      false
    rescue ex : CrystalPath::NotFoundError
      message = "can't find file '#{ex.filename}'"
      notes = [] of String

      # FIXME: as(String) should not be necessary
      if ex.filename.as(String).starts_with? '.'
        if relative_to
          message += " relative to '#{relative_to}'"
        end
      else
        notes << <<-NOTE
            If you're trying to require a shard:
            - Did you remember to run `shards install`?
            - Did you make sure you're running the compiler in the same directory as your shard.yml?
            NOTE
      end

      node.raise "#{message}\n\n#{notes.join("\n")}"
    rescue ex : Crystal::Exception
      node.raise "while requiring \"#{node.string}\"", ex
    rescue ex
      raise ::Exception.new("while requiring \"#{node.string}\"", ex)
    end
  end
end

class Crystal::Compiler
  def permissive_compile(source : Source | Array(Source), output_filename : String) : Result
    source = [source] unless source.is_a?(Array)
    program = new_program(source)
    node = parse program, source
    node = program.permissive_semantic node, cleanup: !no_cleanup?
    Result.new program, node
  end
end

class Crystal::Program
  def permissive_semantic(node : ASTNode, cleanup = true) : ASTNode
    node, processor = top_level_semantic(node)

    begin
      @progress_tracker.stage("Semantic (ivars initializers)") do
        visitor = InstanceVarsInitializerVisitor.new(self)
        visit_with_finished_hooks(node, visitor)
        visitor.finish
      end

      @progress_tracker.stage("Semantic (cvars initializers)") do
        visit_class_vars_initializers(node)
      end

      # Check that class vars without an initializer are nilable,
      # give an error otherwise
      processor.check_non_nilable_class_vars_without_initializers

      result = @progress_tracker.stage("Semantic (main)") do
        visit_main(node, process_finished_hooks: true, cleanup: cleanup)
      end

      @progress_tracker.stage("Semantic (cleanup)") do
        cleanup_types
        cleanup_files
      end

      @progress_tracker.stage("Semantic (recursive struct check)") do
        RecursiveStructChecker.new(self).run
      end

      result
    rescue
      node
    end
  end
end

struct Crystal::TypeDeclarationProcessor
  private def declare_meta_type_var(vars, owner, name, info : TypeGuessVisitor::TypeInfo, freeze_type = true)
    type = info.type
    type = Type.merge!(type, @program.nil) unless info.outside_def
    # add `location: info.location` argument to preserve TypeInfo location
    declare_meta_type_var(vars, owner, name, type, freeze_type: freeze_type, location: info.location)
  end
end
