class Problem
  include Mongoid::Document

  include Mongoid::Timestamps::Created::Short
  field :pcode,             type: String, default: ''
  field :pname,             type: String, default: ''
  field :statement,         type: String, default: ''
  field :state,             type: Boolean, default: true
  field :time_limit,        type: Float, default: '1.0'
  field :memory_limit,      type: Integer, default: 268_435_456
  field :source_limit,      type: Integer, default: 51_200
  field :submissions_count, type: Integer, default: 0
  field :max_score,         type: Integer, default: 20

end
