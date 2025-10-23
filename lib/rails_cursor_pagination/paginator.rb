# frozen_string_literal: true

module RailsCursorPagination
  # Use this Paginator class to effortlessly paginate through ActiveRecord
  # relations using cursor pagination. For more details on how this works,
  # read the top-level documentation of the `RailsCursorPagination` module.
  #
  # Usage:
  #     RailsCursorPagination::Paginator
  #       .new(relation, order_by: :author, first: 2, after: "WyJKYW5lIiw0XQ==")
  #       .fetch
  #
  class Paginator
    # Create a new instance of the `RailsCursorPagination::Paginator`
    #
    # @param relation [ActiveRecord::Relation]
    #   Relation that will be paginated.
    # @param limit [Integer, nil]
    #   Number of records to return in pagination. Can be combined with either
    #   `after` or `before` as an alternative to `first` or `last`.
    # @param first [Integer, nil]
    #   Number of records to return in a forward pagination. Can be combined
    #   with `after`.
    # @param after [String, nil]
    #   Cursor to paginate forward from. Can be combined with `first`.
    # @param last [Integer, nil]
    #   Number of records to return. Must be used together with `before`.
    # @param before [String, nil]
    #   Cursor to paginate upto (excluding). Can be combined with `last`.
    # @param order_by [Symbol, String, Array<Symbol>, Array<String>, nil]
    #   Column(s) to order by. If none is provided, will default to ID column.
    #   Can be a single field or an array of fields for multi-field sorting.
    #   NOTE: this will cause the query to filter on all the given columns as
    #   well as the ID column. So you might want to add a compound index to your
    #   database similar to:
    #   ```sql
    #     CREATE INDEX <index_name> ON <table_name> (<order_by_field1>, <order_by_field2>, id)
    #   ```
    # @param order [Symbol, nil]
    #   Ordering to apply, either `:asc` or `:desc`. Defaults to `:asc`.
    #   This applies to all order_by fields.
    # @param order_query [String, nil]
    #   Query string containing order parameters (e.g., "name:asc,created_at:desc").
    #   This will override order_by and order parameters if provided.
    #
    # @raise [RailsCursorPagination::ParameterError]
    #   If any parameter is not valid
    def initialize(relation, limit: nil, first: nil, after: nil, last: nil,
                   before: nil, order_by: nil, order: nil, order_query: nil)
      # Parse order query string if provided
      if order_query.present?
        parsed_order = parse_order_query(order_query)
        @order_fields = parsed_order[:fields]
        @order_direction = parsed_order[:direction]
      else
        @order_fields = Array(order_by || :id)
        @order_direction = order || :asc
      end

      ensure_valid_params_values!(relation, @order_direction, limit, first, last)
      ensure_valid_params_combinations!(first, last, limit, before, after)
      @relation = relation

      @cursor = before || after
      @is_forward_pagination = before.blank?

      @page_size =
        first ||
        last ||
        limit ||
        RailsCursorPagination::Configuration.instance.default_page_size

      if Configuration.instance.max_page_size &&
         Configuration.instance.max_page_size < @page_size
        @page_size = Configuration.instance.max_page_size
      end

      @memos = {}
    end

    # Get the paginated result, including the actual `page` with its data items
    # and cursors as well as some meta data in `page_info` and an optional
    # `total` of records across all pages.
    #
    # @param with_total [TrueClass, FalseClass]
    # @return [Hash] with keys :page, :page_info, and optional :total
    def fetch(with_total: false)
      {
        **(with_total ? { total: total } : {}),
        page_info: page_info,
        page: page
      }
    end

    private

    # Ensure that the parameters of this service have valid values, otherwise
    # raise a `RailsCursorPagination::ParameterError`.
    #
    # @param relation [ActiveRecord::Relation]
    #   Relation that will be paginated.
    # @param order [Symbol]
    #   Must be :asc or :desc
    # @param limit [Integer, nil]
    #   Optional, must be positive
    # @param first [Integer, nil]
    #   Optional, must be positive
    # @param last [Integer, nil]
    #   Optional, must be positive
    #   with `first` or `limit`
    #
    # @raise [RailsCursorPagination::ParameterError]
    #   If any parameter is not valid
    def ensure_valid_params_values!(relation, order, limit, first, last)
      unless relation.is_a?(ActiveRecord::Relation)
        raise ParameterError,
              'The first argument must be an ActiveRecord::Relation, but was ' \
              "the #{relation.class} `#{relation.inspect}`"
      end
      unless %i[asc desc].include?(order)
        raise ParameterError,
              "`order` must be either :asc or :desc, but was `#{order}`"
      end
      if first.present? && first.negative?
        raise ParameterError, "`first` cannot be negative, but was `#{first}`"
      end
      if last.present? && last.negative?
        raise ParameterError, "`last` cannot be negative, but was `#{last}`"
      end
      if limit.present? && limit.negative?
        raise ParameterError, "`limit` cannot be negative, but was `#{limit}`"
      end

      true
    end

    # Ensure that the parameters of this service are combined in a valid way.
    # Otherwise raise a +RailsCursorPagination::ParameterError+.
    #
    # @param limit [Integer, nil]
    #   Optional, cannot be combined with `last` or `first`
    # @param first [Integer, nil]
    #   Optional, cannot be combined with `last` or `limit`
    # @param after [String, nil]
    #   Optional, cannot be combined with `before`
    # @param last [Integer, nil]
    #   Optional, requires `before`, cannot be combined
    #   with `first` or `limit`
    # @param before [String, nil]
    #   Optional, cannot be combined with `after`
    #
    # @raise [RailsCursorPagination::ParameterError]
    #   If parameters are combined in an invalid way
    def ensure_valid_params_combinations!(first, last, limit, before, after)
      if first.present? && last.present?
        raise ParameterError, '`first` cannot be combined with `last`'
      end
      if first.present? && limit.present?
        raise ParameterError, '`limit` cannot be combined with `first`'
      end
      if last.present? && limit.present?
        raise ParameterError, '`limit` cannot be combined with `last`'
      end
      if before.present? && after.present?
        raise ParameterError, '`before` cannot be combined with `after`'
      end
      if last.present? && before.blank?
        raise ParameterError, '`last` must be combined with `before`'
      end

      true
    end

    # Get meta information about the current page
    #
    # @return [Hash]
    def page_info
      {
        has_previous_page: previous_page?,
        has_next_page: next_page?,
        start_cursor: start_cursor,
        end_cursor: end_cursor
      }
    end

    # Get the records for the given page along with their cursors
    #
    # @return [Array<Hash>] List of hashes, each with a `cursor` and `data`
    def page
      memoize :page do
        records.map do |item|
          {
            cursor: cursor_for_record(item),
            data: item
          }
        end
      end
    end

    # Get the total number of records in the given relation
    #
    # @return [Integer]
    def total
      memoize(:total) { @relation.reorder('').size }
    end

    # Check if the pagination direction is forward
    #
    # @return [TrueClass, FalseClass]
    def paginate_forward?
      @is_forward_pagination
    end

    # Check if the user requested to order on fields different than the ID. If
    # different fields were requested, we have to change our pagination logic to
    # accommodate for this.
    #
    # @return [TrueClass, FalseClass]
    def custom_order_fields?
      @order_fields != [:id]
    end

    # Check if there is a page before the current one.
    #
    # @return [TrueClass, FalseClass]
    def previous_page?
      if paginate_forward?
        # When paginating forward, we can only have a previous page if we were
        # provided with a cursor and there were records discarded after applying
        # this filter. These records would have to be on previous pages.
        @cursor.present? &&
          filtered_and_sorted_relation.reorder('').size < total
      else
        # When paginating backwards, if we managed to load one more record than
        # requested, this record will be available on the previous page.
        records_plus_one.size > @page_size
      end
    end

    # Check if there is another page after the current one.
    #
    # @return [TrueClass, FalseClass]
    def next_page?
      if paginate_forward?
        # When paginating forward, if we managed to load one more record than
        # requested, this record will be available on the next page.
        records_plus_one.size > @page_size
      else
        # When paginating backward, if applying our cursor reduced the number
        # records returned, we know that the missing records will be on
        # subsequent pages.
        filtered_and_sorted_relation.reorder('').size < total
      end
    end

    # Load the correct records and return them in the right order
    #
    # @return [Array<ActiveRecord>]
    def records
      records = records_plus_one.first(@page_size)

      paginate_forward? ? records : records.reverse
    end

    # Apply limit to filtered and sorted relation that contains one item more
    # than the user-requested page size. This is useful for determining if there
    # is an additional page available without having to do a separate DB query.
    # Then, fetch the records from the database to prevent multiple queries to
    # load the records and count them.
    #
    # @return [ActiveRecord::Relation]
    def records_plus_one
      memoize :records_plus_one do
        filtered_and_sorted_relation.limit(@page_size + 1).load
      end
    end

    # Cursor of the first record on the current page
    #
    # @return [String, nil]
    def start_cursor
      return if page.empty?

      page.first[:cursor]
    end

    # Cursor of the last record on the current page
    #
    # @return [String, nil]
    def end_cursor
      return if page.empty?

      page.last[:cursor]
    end

    # Get the order we need to apply to our SQL query. In case we are paginating
    # backwards, this has to be the inverse of what the user requested, since
    # our database can only apply the limit to following records. In the case of
    # backward pagination, we then reverse the order of the loaded records again
    # in `#records` to return them in the right order to the user.
    #
    # Examples:
    #  - first 2 after 4 ascending
    #    -> SELECT * FROM table WHERE id > 4 ODER BY id ASC LIMIT 2
    #  - first 2 after 4 descending                      ^ as requested
    #    -> SELECT * FROM table WHERE id < 4 ODER BY id DESC LIMIT 2
    #  but:                                              ^ as requested
    #  - last 2 before 4 ascending
    #    -> SELECT * FROM table WHERE id < 4 ODER BY id DESC LIMIT 2
    #  - last 2 before 4 descending                      ^ reversed
    #    -> SELECT * FROM table WHERE id > 4 ODER BY id ASC LIMIT 2
    #                                                    ^ reversed
    #
    # @return [Symbol] Either :asc or :desc
    def pagination_sorting
      return @order_direction if paginate_forward?

      @order_direction == :asc ? :desc : :asc
    end

    # Get the right operator to use in the SQL WHERE clause for filtering based
    # on the given cursor. This is dependent on the requested order and
    # pagination direction.
    #
    # If we paginate forward and want ascending records, or if we paginate
    # backward and want descending records we need records that have a higher
    # value than our cursor.
    #
    # On the contrary, if we paginate forward but want descending records, or
    # if we paginate backwards and want ascending records, we need them to have
    # lower values than our cursor.
    #
    # Examples:
    #  - first 2 after 4 ascending
    #    -> SELECT * FROM table WHERE id > 4 ODER BY id ASC LIMIT 2
    #  - last 2 before 4 descending      ^ records with higher value than cursor
    #    -> SELECT * FROM table WHERE id > 4 ODER BY id ASC LIMIT 2
    #  but:                              ^ records with higher value than cursor
    #  - first 2 after 4 descending
    #    -> SELECT * FROM table WHERE id < 4 ODER BY id DESC LIMIT 2
    #  - last 2 before 4 ascending       ^ records with lower value than cursor
    #    -> SELECT * FROM table WHERE id < 4 ODER BY id DESC LIMIT 2
    #                                    ^ records with lower value than cursor
    #
    # @return [String] either '<' or '>'
    def filter_operator
      if paginate_forward?
        @order_direction == :asc ? '>' : '<'
      else
        @order_direction == :asc ? '<' : '>'
      end
    end

    # The value our relation is filtered by. This is either just the cursor's ID
    # if we use the default order, or it is the combination of the custom order
    # fields' values and its ID, joined by dashes.
    #
    # @return [Integer, String]
    def filter_value
      return decoded_cursor.id unless custom_order_fields?

      "#{decoded_cursor.order_field_values.join('-')}-#{decoded_cursor.id}"
    end

    # Generate a cursor for the given record and ordering fields. The cursor
    # encodes all the data required to then paginate based on it with the given
    # ordering fields.
    #
    # If we only order by ID, the cursor doesn't need to include any other data.
    # But if we order by any other fields, the cursor needs to include both the
    # values from these other fields as well as the records ID to resolve the order
    # of duplicates in the non-ID fields.
    #
    # @param record [ActiveRecord] Model instance for which we want the cursor
    # @return [String]
    def cursor_for_record(record)
      cursor_class.from_record(record: record, order_fields: @order_fields).encode
    end

    # Decode the provided cursor. Either just returns the cursor's ID or in case
    # of pagination on any other fields, returns a tuple of first the cursor
    # record's other fields' values followed by its ID.
    #
    # @return [Integer, Array]
    def decoded_cursor
      memoize(:decoded_cursor) do
        cursor_class.decode(encoded_string: @cursor, order_fields: @order_fields)
      end
    end

    # Returns the appropriate class for the cursor based on the SQL type of the
    # columns used for ordering the relation.
    #
    # @return [Class<RailsCursorPagination::Cursor>]
    def cursor_class
      # Check if any of the order fields is a timestamp
      has_timestamp = @order_fields.any? do |field|
        @relation.column_for_attribute(field).sql_type_metadata.type == :datetime
      end

      if has_timestamp
        TimestampCursor
      else
        Cursor
      end
    end

    # Ensure that the relation has the ID column and any potential `order_by`
    # columns selected. These are required to generate the record's cursor and
    # therefore it's crucial that they are part of the selected fields.
    #
    # @return [ActiveRecord::Relation]
    def relation_with_cursor_fields
      return @relation if @relation.select_values.blank? ||
                          @relation.select_values.include?('*')

      relation = @relation

      unless @relation.select_values.include?(:id)
        relation = relation.select(:id)
      end

      if custom_order_fields?
        @order_fields.each do |field|
          unless @relation.select_values.include?(field)
            relation = relation.select(field)
          end
        end
      end

      relation
    end

    # The given relation with the right ordering applied. Takes custom order
    # columns as well as custom direction and pagination into account.
    #
    # @return [ActiveRecord::Relation]
    def sorted_relation
      unless custom_order_fields?
        return relation_with_cursor_fields.reorder id: pagination_sorting.upcase
      end

      # Check if we have complex SQL expressions (like CASE WHEN)
      if has_complex_order_expressions?
        return handle_complex_order_relation
      end

      # Build the order hash for multiple fields
      order_hash = {}
      @order_fields.each do |field|
        order_hash[field] = pagination_sorting.upcase
      end
      order_hash[:id] = pagination_sorting.upcase

      relation_with_cursor_fields.reorder(order_hash)
    end

    # Return a properly escaped reference to the ID column prefixed with the
    # table name. This prefixing is important in case of another model having
    # been joined to the passed relation.
    #
    # @return [String (frozen)]
    def id_column
      escaped_table_name = @relation.quoted_table_name
      escaped_id_column = @relation.connection.quote_column_name(:id)

      "#{escaped_table_name}.#{escaped_id_column}".freeze
    end

    # Applies the filtering based on the provided cursor and order columns to the
    # sorted relation.
    #
    # In case custom `order_by` fields are provided, we have to filter based on
    # these fields and the ID column to ensure reproducible results.
    #
    # To better understand this, let's consider our example with the `posts`
    # table. Say that we're paginating forward and add `order_by: [:author, :created_at]` to
    # the call, and if the cursor that is passed encodes `['Jane', '2023-01-01', 4]`. In this
    # case we will have to select all posts that either have an author whose
    # name is alphanumerically greater than 'Jane', or if the author is 'Jane' and
    # created_at is greater than '2023-01-01', or if both author and created_at are equal
    # we have to ensure that the post's ID is greater than `4`.
    #
    # So our SQL WHERE clause needs to be something like:
    #    WHERE author > 'Jane' 
    #       OR (author = 'Jane' AND created_at > '2023-01-01')
    #       OR (author = 'Jane' AND created_at = '2023-01-01' AND id > 4)
    #
    # @return [ActiveRecord::Relation]
    def filtered_and_sorted_relation
      memoize :filtered_and_sorted_relation do
        next sorted_relation if @cursor.blank?

        unless custom_order_fields?
          next sorted_relation.where "#{id_column} #{filter_operator} ?",
                                     decoded_cursor.id
        end

        # Handle complex expressions differently
        if has_complex_order_expressions?
          build_complex_expression_where_clause
        else
          # Build complex WHERE clause for multiple fields
          build_multi_field_where_clause
        end
      end
    end

    # Builds a complex WHERE clause for multi-field sorting
    #
    # @return [ActiveRecord::Relation]
    def build_multi_field_where_clause
      conditions = []
      values = []
      
      # Build conditions for each field level
      (0...@order_fields.size).each do |level|
        condition_parts = []
        value_parts = []
        
        # Add equality conditions for all previous fields
        (0...level).each do |i|
          field = @order_fields[i]
          condition_parts << "#{field} = ?"
          value_parts << decoded_cursor.order_field_values[i]
        end
        
        # Add the comparison condition for the current field
        current_field = @order_fields[level]
        condition_parts << "#{current_field} #{filter_operator} ?"
        value_parts << decoded_cursor.order_field_values[level]
        
        conditions << "(#{condition_parts.join(' AND ')})"
        values.concat(value_parts)
      end
      
      # Add the final condition with ID comparison
      if @order_fields.any?
        final_condition_parts = []
        final_value_parts = []
        
        # Add equality conditions for all order fields
        @order_fields.each_with_index do |field, i|
          final_condition_parts << "#{field} = ?"
          final_value_parts << decoded_cursor.order_field_values[i]
        end
        
        # Add ID comparison
        final_condition_parts << "#{id_column} #{filter_operator} ?"
        final_value_parts << decoded_cursor.id
        
        conditions << "(#{final_condition_parts.join(' AND ')})"
        values.concat(final_value_parts)
      end
      
      sorted_relation.where(conditions.join(' OR '), *values)
    end

    # Builds a WHERE clause for complex expressions like CASE WHEN
    #
    # @return [ActiveRecord::Relation]
    def build_complex_expression_where_clause
      # For complex expressions, we need to use the expression values directly
      # in the WHERE clause rather than trying to parse field names
      
      if @order_fields.size == 1
        # Single complex expression
        expression = @order_fields.first
        cursor_value = decoded_cursor.order_field_values.first
        
        # Build WHERE clause using the complex expression
        where_clause = "(#{expression}) #{filter_operator} ?"
        sorted_relation.where(where_clause, cursor_value)
      else
        # Multiple fields with at least one complex expression
        # This is more complex and might need custom handling
        # For now, fall back to a simplified approach
        build_simplified_complex_where_clause
      end
    end

    # Simplified approach for complex expressions with multiple fields
    #
    # @return [ActiveRecord::Relation]
    def build_simplified_complex_where_clause
      # For multiple complex expressions, we use a simplified approach
      # that compares the complex expression values and falls back to ID comparison
      
      conditions = []
      values = []
      
      # Add conditions for each complex expression
      @order_fields.each_with_index do |field, index|
        if field.is_a?(String) && is_complex_expression?(field)
          conditions << "(#{field}) #{filter_operator} ?"
          values << decoded_cursor.order_field_values[index]
        else
          conditions << "#{field} #{filter_operator} ?"
          values << decoded_cursor.order_field_values[index]
        end
      end
      
      # Add ID comparison as tie-breaker
      conditions << "#{id_column} #{filter_operator} ?"
      values << decoded_cursor.id
      
      # For complex expressions, we need to use OR logic for the comparison
      # This is a simplified approach - in practice, you might need more sophisticated logic
      where_clause = conditions.join(' OR ')
      sorted_relation.where(where_clause, *values)
    end

    # Check if a field is a complex SQL expression (helper method)
    #
    # @param field [String, Symbol]
    # @return [Boolean]
    def is_complex_expression?(field)
      field.is_a?(String) && (
        field.include?('CASE') ||
        field.include?('WHEN') ||
        field.include?('THEN') ||
        field.include?('ELSE') ||
        field.include?('END') ||
        field.match?(/\(.*\)/) # Contains parentheses (function calls)
      )
    end

    # Check if any of the order fields contains complex SQL expressions
    # like CASE WHEN, function calls, etc.
    #
    # @return [Boolean]
    def has_complex_order_expressions?
      @order_fields.any? do |field|
        field.is_a?(String) && (
          field.include?('CASE') ||
          field.include?('WHEN') ||
          field.include?('THEN') ||
          field.include?('ELSE') ||
          field.include?('END') ||
          field.match?(/\(.*\)/) # Contains parentheses (function calls)
        )
      end
    end

    # Handle relations with complex order expressions by preserving the original
    # ordering and applying pagination direction logic
    #
    # @return [ActiveRecord::Relation]
    def handle_complex_order_relation
      # For complex expressions, we need to preserve the original ordering
      # and handle direction changes differently
      if pagination_sorting != @order_direction
        # We need to reverse the complex expression for backward pagination
        reversed_order = reverse_complex_order_expression
        relation_with_cursor_fields.reorder(reversed_order)
      else
        # Keep the original ordering for forward pagination
        relation_with_cursor_fields
      end
    end

    # Reverse a complex order expression for backward pagination
    #
    # @return [String, Hash]
    def reverse_complex_order_expression
      # For complex expressions, we need to reverse the entire ORDER BY clause
      # This is a simplified approach - in practice, you might need more sophisticated
      # parsing depending on the complexity of your expressions
      if @order_fields.size == 1 && @order_fields.first.is_a?(String)
        # Single complex expression - reverse it by adding DESC/ASC
        field = @order_fields.first
        if field.match?(/\b(ASC|DESC)\b/i)
          # Replace existing direction
          field.gsub(/\b(ASC|DESC)\b/i, pagination_sorting.upcase)
        else
          # Add direction
          "#{field} #{pagination_sorting.upcase}"
        end
      else
        # Multiple fields - this is more complex and might need custom handling
        # For now, fall back to simple field reversal
        order_hash = {}
        @order_fields.each do |field|
          if field.is_a?(String) && field.match?(/\b(ASC|DESC)\b/i)
            order_hash[field] = pagination_sorting.upcase
          else
            order_hash[field] = pagination_sorting.upcase
          end
        end
        order_hash[:id] = pagination_sorting.upcase
        order_hash
      end
    end

    # Parse order query string into fields and direction
    #
    # Supports formats like:
    # - "name:asc" -> { fields: [:name], direction: :asc }
    # - "name:asc,created_at:desc" -> { fields: [:name, :created_at], direction: :asc }
    # - "name" -> { fields: [:name], direction: :asc }
    # - "name,created_at" -> { fields: [:name, :created_at], direction: :asc }
    #
    # @param order_query [String]
    #   Query string containing order parameters
    # @return [Hash] with :fields and :direction keys
    # @raise [RailsCursorPagination::ParameterError]
    #   If the order query string is invalid
    def parse_order_query(order_query)
      return { fields: [:id], direction: :asc } if order_query.blank?

      fields = []
      directions = []
      
      # Split by comma to handle multiple fields
      order_parts = order_query.split(',').map(&:strip)
      
      order_parts.each do |part|
        if part.include?(':')
          # Format: "field:direction"
          field, direction = part.split(':', 2).map(&:strip)
          # Keep complex expressions as strings, convert simple fields to symbols
          field = is_complex_expression?(field) ? field : field.to_sym
          fields << field
          directions << direction.to_sym
        else
          # Format: "field" (default to asc)
          # Keep complex expressions as strings, convert simple fields to symbols
          field = is_complex_expression?(part) ? part : part.to_sym
          fields << field
          directions << :asc
        end
      end
      
      # Validate directions
      directions.each do |direction|
        unless %i[asc desc].include?(direction)
          raise ParameterError, "Invalid order direction '#{direction}'. Must be 'asc' or 'desc'"
        end
      end
      
      # For multi-field sorting, we need to handle direction per field
      # For now, we'll use the first direction for all fields
      # In the future, this could be enhanced to support per-field directions
      primary_direction = directions.first
      
      { fields: fields, direction: primary_direction }
    end

    # Ensures that given block is only executed exactly once and on subsequent
    # calls returns result from first execution. Useful for memoizing methods.
    #
    # @param key [Symbol]
    #   Name or unique identifier of the method that is being memoized
    # @yieldreturn [Object]
    # @return [Object] Whatever the block returns
    def memoize(key, &_block)
      return @memos[key] if @memos.key?(key)

      @memos[key] = yield
    end
  end
end
