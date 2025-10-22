# frozen_string_literal: true

module RailsCursorPagination
  # Cursor class that's used to uniquely identify a record and serialize and
  # deserialize this cursor so that it can be used for pagination.
  # This class expects the `order_field` of the record to be a timestamp and is
  # to be used only when sorting a
  class TimestampCursor < Cursor
    class << self
      # Decode the provided encoded cursor. Returns an instance of this
      # `RailsCursorPagination::Cursor` class containing both the ID and the
      # ordering field values. The ordering fields are expected to be timestamps
      # and are always decoded in the UTC timezone.
      #
      # @param encoded_string [String]
      #   The encoded cursor
      # @param order_fields [Array<Symbol>]
      #   The columns that are being ordered on. They need to be timestamps of a
      #   class that responds to `#strftime`.
      # @raise [RailsCursorPagination::InvalidCursorError]
      #   In case the given `encoded_string` cannot be decoded properly
      # @return [RailsCursorPagination::TimestampCursor]
      #   Instance of this class with a properly decoded timestamp cursor
      def decode(encoded_string:, order_fields:)
        decoded = JSON.parse(Base64.strict_decode64(encoded_string))
        order_fields = Array(order_fields)
        
        expected_size = order_fields.size + 1 # +1 for ID
        unless decoded.is_a?(Array) && decoded.size == expected_size
          raise InvalidCursorError,
                "The given cursor `#{encoded_string}` was decoded as " \
                "`#{decoded}` but could not be parsed"
        end

        order_field_values = decoded[0...-1].map do |timestamp_value|
          # Turn the order field value into a `Time` instance in UTC. A Rational
          # number allows us to represent fractions of seconds, including the
          # microseconds. In this way we can preserve the order of items with a
          # microsecond precision.
          # This also allows us to keep the size of the cursor small by using
          # just a number instead of having to pass seconds and the fraction of
          # seconds separately.
          Time.at(timestamp_value.to_r / (10**6)).utc
        end

        new(
          id: decoded.last,
          order_fields: order_fields,
          order_field_values: order_field_values
        )
      rescue ArgumentError, JSON::ParserError
        raise InvalidCursorError,
              "The given cursor `#{encoded_string}` " \
              'could not be decoded to a timestamp'
      end
    end

    # Initializes the record. Overrides `Cursor`'s initializer making all params
    # mandatory.
    #
    # @param id [Integer]
    #   The ID of the cursor record
    # @param order_fields [Array<Symbol>]
    #   The columns or virtual columns for ordering
    # @param order_field_values [Array<Object>]
    #   The values that the +order_fields+ of the record contains
    def initialize(id:, order_fields:, order_field_values:)
      super id: id,
            order_fields: order_fields,
            order_field_values: order_field_values
    end

    # Encodes the cursor as an array containing the timestamps as microseconds
    # from UNIX epoch and the id of the object
    #
    # @raise [RailsCursorPagination::ParameterError]
    #   The order field values need to respond to `#strftime` to use the
    #   `TimestampCursor` class. Otherwise, a `ParameterError` is raised.
    # @return [String]
    def encode
      @order_field_values.each_with_index do |value, index|
        unless value.respond_to?(:strftime)
          raise ParameterError,
                "Could not encode #{@order_fields[index]} " \
                "with value #{value}." \
                'It does not respond to #strftime. Is it a timestamp?'
        end
      end

      timestamp_values = @order_field_values.map do |value|
        value.strftime('%s%6N').to_i
      end

      Base64.strict_encode64(
        (timestamp_values + [@id]).to_json
      )
    end
  end
end
