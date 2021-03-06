require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

describe "Aspects combined" do
  it "should work" do
    klass = create_test_class

    aspector(klass) do
      before :test do value << "do_before" end

      after  :test do |result|
        value << "do_after"
        result
      end

      around :test do |proxy, &block|
        value   <<  "do_around_before"
        result  =   proxy.call &block
        value   <<  "do_around_after"
        result
      end
    end

    aspector(klass) do
      before :test do value << "do_before2" end

      after  :test do |result|
        value << "do_after2"
        result
      end

      around :test do |proxy, &block|
        value   <<  "do_around_before2"
        result  =   proxy.call &block
        value   <<  "do_around_after2"
        result
      end
    end

    obj = klass.new
    obj.test
    obj.value.should == %w"
      do_before2 do_around_before2
      do_before do_around_before
      test
      do_around_after do_after
      do_around_after2 do_after2"
  end
end
