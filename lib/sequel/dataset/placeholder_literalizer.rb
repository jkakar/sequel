module Sequel
  class Dataset
    # PlaceholderLiteralizer allows you to record the application of arbitrary changes
    # to a dataset with placeholder arguments, recording where those placeholder arguments
    # are used in the query.  When running the query, the literalization process is much
    # faster as Sequel can skip most of the work it normal has to do when literalizing a
    # dataset.
    #
    # Basically, this enables optimizations that allow Sequel to cache the SQL produced
    # for a given dataset, so that it doesn't need to recompute that information every
    # time.
    #
    # Example:
    #
    #   loader = Sequel::Dataset::PlaceholderLiteralizer.loader(DB[:items]) do |pl, ds|
    #     ds.where(:id=>pl.arg).exclude(:name=>pl.arg).limit(1)
    #   end
    #   loader.first(1, "foo")
    #   # SELECT * FROM items WHERE ((id = 1) AND (name != 'foo')) LIMIT 1
    #   loader.first(2, "bar")
    #   # SELECT * FROM items WHERE ((id = 2) AND (name != 'bar')) LIMIT 1
    #
    # Caveats:
    #
    # Note that this method does not handle all possible cases.  For example:
    #
    #   loader = Sequel::Dataset::PlaceholderLiteralizer.loader(DB[:items]) do |pl, ds|
    #     ds.join(pl.arg, :item_id=>:id)
    #   end
    #   loader(:cart_items)
    #  
    # Will not qualify the item_id column with cart_items.  In this type of situation it's
    # best to add a table alias when joining:
    #
    #   loader = Sequel::Dataset::PlaceholderLiteralizer.loader(DB[:items]) do |pl, ds|
    #     ds.join(Sequel.as(pl.arg, :t), :item_id=>:id)
    #   end
    #   loader(:cart_items)
    #
    # There are other similar cases that are not handled, mainly when Sequel changes the
    # SQL produced depending on the types of the arguments.
    class PlaceholderLiteralizer
      # A placeholder argument used by the PlaceholderLiteralizer.  This records the offset
      # that the argument should be used in the resulting SQL.
      class Argument
        # Set the recorder, the argument position, and any transforming block to use
        # for this placeholder.
        def initialize(recorder, pos, transformer=nil)
          @recorder = recorder
          @pos = pos
          @transformer = transformer
        end

        # Record the SQL query offset, argument position, and transforming block where the
        # argument should be literalized.
        def sql_literal_append(ds, sql)
          @recorder.use(sql, @pos, @transformer)
        end

        # Return a new Argument object for the same recorder and argument position, but with a
        # different transformer block.
        def transform(&block)
          Argument.new(@recorder, @pos, block)
        end
      end

      # Records the offsets at which the placeholder arguments are used in
      # the SQL query.
      class Recorder
        # Yields the receiver and the dataset to the block, which should
        # call #arg on the receiver for each placeholder argument, and
        # return the dataset that you want to load.
        def loader(dataset)
          @argn = -1
          @args = []
          ds = yield self, dataset
          sql = ds.sql

          last_offset = 0
          fragments = @args.map do |used_sql, offset, arg, t|
            raise Error, "placeholder literalizer argument literalized into different string than dataset returned" unless used_sql.equal?(sql)
            a = [sql[last_offset...offset], arg, t]
            last_offset = offset
            a
          end
          final_sql = sql[last_offset..-1]

          arity = @argn+1
          PlaceholderLiteralizer.new(ds.clone, fragments, final_sql, arity)
        end

        # Return an Argument with the specified position, or the next position. In
        # general you shouldn't mix calls with an argument and calls without an
        # argument for the same receiver.
        def arg(v=(no_arg_given = true; @argn+=1))
          unless no_arg_given
            @argn = v if @argn < v
          end
          Argument.new(self, v)
        end

        # Record the offset at which the argument is used in the SQL query, and any
        # transforming
        def use(sql, arg, transformer)
          @args << [sql, sql.length, arg, transformer]
        end
      end

      # Create a PlaceholderLiteralizer by yielding a Recorder and dataset to the
      # given block, recording the offsets at which the recorders arguments
      # are used in the query.
      def self.loader(dataset, &block)
        Recorder.new.loader(dataset, &block)
      end

      # Save the dataset, array of SQL fragments, and ending SQL string.
      def initialize(dataset, fragments, final_sql, arity)
        @dataset = dataset
        @fragments = fragments
        @final_sql = final_sql
        @arity = arity
      end

      # Return an array of all objects by running the SQL query for the given arguments.
      # If a block is given, yields all objects to the block after loading them.
      def all(*args, &block)
        @dataset.with_sql_all(sql(*args), &block)
      end

      # Run the SQL query for the given arguments, yielding each returned row to the block.
      def each(*args, &block)
        @dataset.with_sql_each(sql(*args), &block)
      end

      # Run the SQL query for the given arguments, returning the first row.
      def first(*args)
        @dataset.with_sql_first(sql(*args))
      end

      # Run the SQL query for the given arguments, returning the first value.  For this to
      # make sense, the dataset should return a single row with a single value (or no rows).
      def get(*args)
        @dataset.with_sql_single_value(sql(*args))
      end

      # Return the SQL query to use for the given arguments.
      def sql(*args)
        raise Error, "wrong number of arguments (#{args.length} for #{@arity})" unless args.length == @arity
        s = ''
        ds = @dataset
        @fragments.each do |sql, i, transformer|
          s << sql
          v = args.fetch(i)
          v = transformer.call(v) if transformer
          ds.literal_append(s, v)
        end
        if sql = @final_sql
          s << sql
        end
        s
      end
    end
  end
end