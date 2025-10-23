# frozen_string_literal: true

require 'base64'

module RailsCursorPagination
  # Cursor class that's used to uniquely identify a record and serialize and
  # deserialize this cursor so that it can be used for pagination.
  class Cursor
    attr_reader :id, :order_field_values

    class << self
      # Generate a cursor for the given record and ordering fields. The cursor
      # encodes all the data required to then paginate based on it with the
      # given ordering fields.
      #
      # @param record [ActiveRecord]
      #   Model instance for which we want the cursor
      # @param order_fields [Symbol, Array<Symbol>]
      #   Column(s) or virtual column(s) of the record that the relation is ordered by
      # @return [Cursor]
      def from_record(record:, order_fields: :id)
        order_fields = Array(order_fields)
        order_field_values = order_fields.map do |field|
          if field.is_a?(String) && is_complex_expression?(field)
            # For complex expressions, we need to evaluate them in the database context
            evaluate_complex_expression(record, field)
          else
            record[field]
          end
        end
        
        new(id: record.id, order_fields: order_fields,
            order_field_values: order_field_values)
      end

      # Decode the provided encoded cursor. Returns an instance of this
      # +RailsCursorPagination::Cursor+ class containing either just the
      # cursor's ID or in case of pagination on any other field(s), containing
      # both the ID and the ordering field values.
      #
      # @param encoded_string [String]
      #   The encoded cursor
      # @param order_fields [Symbol, Array<Symbol>]
      #   Optional. The column(s) that is being ordered on in case it's not the ID
      #   column
      # @return [RailsCursorPagination::Cursor]
      def decode(encoded_string:, order_fields: :id)
        decoded = JSON.parse(Base64.strict_decode64(encoded_string))
        order_fields = Array(order_fields)
        
        if order_fields == [:id]
          if decoded.is_a?(Array)
            raise InvalidCursorError,
                  "The given cursor `#{encoded_string}` was decoded as " \
                  "`#{decoded}` but could not be parsed"
          end
          new(id: decoded, order_fields: [:id])
        else
          expected_size = order_fields.size + 1 # +1 for ID
          unless decoded.is_a?(Array) && decoded.size == expected_size
            raise InvalidCursorError,
                  "The given cursor `#{encoded_string}` was decoded as " \
                  "`#{decoded}` but could not be parsed"
          end
          order_field_values = decoded[0...-1] # All but last element
          id = decoded.last
          new(id: id, order_fields: order_fields,
              order_field_values: order_field_values)
        end
      rescue ArgumentError, JSON::ParserError
        raise InvalidCursorError,
              "The given cursor `#{encoded_string}` could not be decoded"
      end
    end

    # Initializes the record
    #
    # @param id [Integer]
    #   The ID of the cursor record
    # @param order_fields [Array<Symbol>]
    #   The columns or virtual columns for ordering
    # @param order_field_values [Array<Object>]
    #   Optional. The values that the +order_fields+ of the record contains in
    #   case that the order fields are not just the ID
    def initialize(id:, order_fields: [:id], order_field_values: nil)
      @id = id
      @order_fields = Array(order_fields)
      @order_field_values = order_field_values

      return if !custom_order_fields? || !order_field_values.nil?

      raise ParameterError, 'The `order_fields` were set to ' \
                            "`#{@order_fields.inspect}` but " \
                            'no `order_field_values` were set'
    end

    # Generate an encoded string for this cursor. The cursor encodes all the
    # data required to then paginate based on it with the given ordering fields.
    #
    # If we only order by ID, the cursor doesn't need to include any other data.
    # But if we order by any other field(s), the cursor needs to include both the
    # values from these other fields as well as the records ID to resolve the order
    # of duplicates in the non-ID fields.
    #
    # @return [String]
    def encode
      unencoded_cursor =
        if custom_order_fields?
          @order_field_values + [@id]
        else
          @id
        end
      Base64.strict_encode64(unencoded_cursor.to_json)
    end

    private

    # Returns true when the order has been overridden from the default (ID)
    #
    # @return [Boolean]
    def custom_order_fields?
      @order_fields != [:id]
    end

    # Check if a field is a complex SQL expression
    #
    # @param field [String, Symbol]
    # @return [Boolean]
    def self.is_complex_expression?(field)
      field.is_a?(String) && (
        field.include?('CASE') ||
        field.include?('WHEN') ||
        field.include?('THEN') ||
        field.include?('ELSE') ||
        field.include?('END') ||
        field.match?(/\(.*\)/) # Contains parentheses (function calls)
      )
    end

    # Evaluate a complex expression for a given record
    #
    # @param record [ActiveRecord]
    # @param expression [String]
    # @return [Object]
    def self.evaluate_complex_expression(record, expression)
      # For complex expressions, we need to execute a query to get the value
      # This is a simplified approach - in practice, you might need more sophisticated
      # handling depending on the complexity of your expressions
      
      begin
        # Get the record's class and connection
        model_class = record.class
        connection = model_class.connection
        
        # Build a query to evaluate the expression for this specific record
        sql = "SELECT (#{expression}) as expr_value FROM #{model_class.table_name} WHERE id = ?"
        
        result = connection.select_one(sql, record.id)
        result['expr_value']
      rescue => e
        # If complex expression evaluation fails, fall back to a simple approach
        # This ensures pagination doesn't break even if cursor generation fails
        puts "Warning: Failed to evaluate complex expression '#{expression}': #{e.message}"
        0 # Return a default value
      end
    end
  end
end
