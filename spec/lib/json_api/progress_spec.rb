require 'spec_helper'

describe JsonApi::Progress do
  it "should have defined pagination defaults" do
    expect(JsonApi::Progress::TYPE_KEY).to eq('progress')
    expect(JsonApi::Progress::DEFAULT_PAGE).to eq(10)
    expect(JsonApi::Progress::MAX_PAGE).to eq(25)
  end

  describe "build_json" do
    it "should not include unlisted settings" do
      p = Progress.new(settings: {'hat' => 'black'})
      expect(JsonApi::Progress.build_json(p).keys).not_to be_include('hat')
    end
    
    it "should return appropriate values" do
      p = Progress.new(settings: {})
      ['id', 'status_url', 'status'].each do |key|
        expect(JsonApi::Progress.build_json(p).keys).to be_include(key)
      end
      expect(JsonApi::Progress.build_json(p).keys).not_to be_include('started_at')
      expect(JsonApi::Progress.build_json(p).keys).not_to be_include('finished_at')
      expect(JsonApi::Progress.build_json(p).keys).not_to be_include('result')
      
      p.started_at = Time.now
      expect(JsonApi::Progress.build_json(p).keys).to be_include('started_at')
      expect(JsonApi::Progress.build_json(p).keys).not_to be_include('finished_at')
      expect(JsonApi::Progress.build_json(p).keys).not_to be_include('result')
      
      p.finished_at = Time.now
      expect(JsonApi::Progress.build_json(p).keys).to be_include('started_at')
      expect(JsonApi::Progress.build_json(p).keys).to be_include('finished_at')
      expect(JsonApi::Progress.build_json(p).keys).to be_include('result')
    end

    it "should flag a progress as errored if it got stuck" do
      p  = Progress.new(settings: {})
      p.updated_at = 6.hours.ago
      p.started_at = 6.hours.ago
      hash = JsonApi::Progress.build_json(p)
      expect(hash['status']).to eq('errored')
      expect(hash['result']['error']).to eq('progress job is taking too long, possibly crashed')
    end

    it "should return an errr result if any" do
      p = Progress.create
      expect(p.settings['error_result']).to eq(nil)
      Progress.set_error("bacon!")
      p.error!(nil)
      expect(p.settings['error_result']).to eq('bacon!')
      hash = JsonApi::Progress.build_json(p)
      expect(hash['status']).to eq('errored')
      expect(hash['result']).to eq('bacon!')
    end
  end

  describe "update_minutes_estimate" do
    it "should update if found" do
      p = Progress.create
      h = {}
      h[Worker.thread_id] = p
      Progress.class_variable_set(:@@running_progresses, h)
      Progress.update_minutes_estimate(12)
      expect(p.reload.settings['minutes_estimate']).to eq(12)
      Progress.update_minutes_estimate(99)
      expect(p.reload.settings['minutes_estimate']).to eq(99)
    end

    it "should not error if not found" do
      Progress.class_variable_set(:@@running_progresses, {})
      Progress.update_minutes_estimate(12)
    end
  end
end
