# frozen_string_literal: true

RSpec.describe RailsCursorPagination::Paginator do
  subject(:instance) { described_class.new(relation, **params) }

  let(:relation) { Post.all }
  let(:params) { {} }

  describe 'Order Query Fix' do
    let(:post_1) { Post.create! id: 1, author: 'John', content: 'Post 1' }
    let(:post_2) { Post.create! id: 2, author: 'Jane', content: 'Post 2' }
    let(:post_3) { Post.create! id: 3, author: 'Alice', content: 'Post 3' }

    let!(:posts) { [post_1, post_2, post_3] }

    context 'with simple author ordering' do
      let(:params) do
        {
          order_query: 'author:asc',
          first: 3
        }
      end

      it 'returns results ordered by author' do
        result = instance.fetch
        
        expect(result[:page]).not_to be_empty
        expect(result[:page].size).to eq(3)
        
        authors = result[:page].map { |item| item[:data].author }
        expect(authors).to eq(['Alice', 'Jane', 'John'])
      end
    end

    context 'with author descending' do
      let(:params) do
        {
          order_query: 'author:desc',
          first: 3
        }
      end

      it 'returns results ordered by author descending' do
        result = instance.fetch
        
        expect(result[:page]).not_to be_empty
        expect(result[:page].size).to eq(3)
        
        authors = result[:page].map { |item| item[:data].author }
        expect(authors).to eq(['John', 'Jane', 'Alice'])
      end
    end

    context 'with CASE WHEN ordering' do
      let(:params) do
        {
          order_query: "CASE WHEN author = 'Jane' THEN 0 ELSE 1 END:asc",
          first: 3
        }
      end

      it 'returns results ordered by CASE WHEN' do
        result = instance.fetch
        
        expect(result[:page]).not_to be_empty
        expect(result[:page].size).to eq(3)
        
        authors = result[:page].map { |item| item[:data].author }
        # Jane should come first (CASE WHEN = 0), then others
        expect(authors.first).to eq('Jane')
        expect(authors.last(2)).to contain_exactly('Alice', 'John')
      end
    end

    context 'with multiple fields' do
      let(:params) do
        {
          order_query: 'author:asc,id:asc',
          first: 3
        }
      end

      it 'returns results ordered by author then id' do
        result = instance.fetch
        
        expect(result[:page]).not_to be_empty
        expect(result[:page].size).to eq(3)
        
        records = result[:page].map { |item| item[:data] }
        expect(records.map(&:author)).to eq(['Alice', 'Jane', 'John'])
        expect(records.map(&:id)).to eq([3, 2, 1])
      end
    end

    context 'with default direction' do
      let(:params) do
        {
          order_query: 'author',
          first: 3
        }
      end

      it 'returns results with default ascending order' do
        result = instance.fetch
        
        expect(result[:page]).not_to be_empty
        expect(result[:page].size).to eq(3)
        
        authors = result[:page].map { |item| item[:data].author }
        expect(authors).to eq(['Alice', 'Jane', 'John'])
      end
    end

    context 'without order_query' do
      let(:params) do
        {
          first: 3
        }
      end

      it 'returns results with default id ordering' do
        result = instance.fetch
        
        expect(result[:page]).not_to be_empty
        expect(result[:page].size).to eq(3)
        
        ids = result[:page].map { |item| item[:data].id }
        expect(ids).to eq([1, 2, 3])
      end
    end

    context 'with pagination' do
      let(:params) do
        {
          order_query: 'author:asc',
          first: 2
        }
      end

      it 'supports cursor pagination' do
        result = instance.fetch
        
        expect(result[:page].size).to eq(2)
        expect(result[:page_info][:has_next_page]).to be true
        
        # Get next page
        next_params = {
          order_query: 'author:asc',
          first: 1,
          after: result[:page_info][:end_cursor]
        }
        
        next_result = described_class.new(relation, **next_params).fetch
        expect(next_result[:page].size).to eq(1)
        expect(next_result[:page].first[:data].author).to eq('John')
      end
    end
  end
end
