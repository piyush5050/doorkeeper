# frozen_string_literal: true

require "spec_helper"
require "bcrypt"

module Doorkeeper
  describe Application do
    let(:clazz) { Doorkeeper::Application }
    let(:require_owner) { Doorkeeper.configuration.instance_variable_set("@confirm_application_owner", true) }
    let(:unset_require_owner) { Doorkeeper.configuration.instance_variable_set("@confirm_application_owner", false) }
    let(:new_application) { FactoryBot.build(:application) }

    let(:uid) { SecureRandom.hex(8) }
    let(:secret) { SecureRandom.hex(8) }

    context "application_owner is enabled" do
      before do
        Doorkeeper.configure do
          orm DOORKEEPER_ORM
          enable_application_owner
        end
      end

      context "application owner is not required" do
        before(:each) do
          unset_require_owner
        end

        it "is valid given valid attributes" do
          expect(new_application).to be_valid
        end
      end

      context "application owner is required" do
        before(:each) do
          require_owner
          @owner = FactoryBot.build_stubbed(:doorkeeper_testing_user)
        end

        it "is invalid without an owner" do
          expect(new_application).not_to be_valid
        end

        it "is valid with an owner" do
          new_application.owner = @owner
          expect(new_application).to be_valid
        end
      end
    end

    it "is invalid without a name" do
      new_application.name = nil
      expect(new_application).not_to be_valid
    end

    it "is invalid without determining confidentiality" do
      new_application.confidential = nil
      expect(new_application).not_to be_valid
    end

    it "generates uid on create" do
      expect(new_application.uid).to be_nil
      new_application.save
      expect(new_application.uid).not_to be_nil
    end

    it "generates uid on create if an empty string" do
      new_application.uid = ""
      new_application.save
      expect(new_application.uid).not_to be_blank
    end

    it "generates uid on create unless one is set" do
      new_application.uid = uid
      new_application.save
      expect(new_application.uid).to eq(uid)
    end

    it "is invalid without uid" do
      new_application.save
      new_application.uid = nil
      expect(new_application).not_to be_valid
    end

    it "is invalid without redirect_uri" do
      new_application.save
      new_application.redirect_uri = nil
      expect(new_application).not_to be_valid
    end

    it "checks uniqueness of uid" do
      app1 = FactoryBot.create(:application)
      app2 = FactoryBot.create(:application)
      app2.uid = app1.uid
      expect(app2).not_to be_valid
    end

    it "expects database to throw an error when uids are the same" do
      app1 = FactoryBot.create(:application)
      app2 = FactoryBot.create(:application)
      app2.uid = app1.uid
      expect { app2.save!(validate: false) }.to raise_error(uniqueness_error)
    end

    it "generate secret on create" do
      expect(new_application.secret).to be_nil
      new_application.save
      expect(new_application.secret).not_to be_nil
    end

    it "generate secret on create if is blank string" do
      new_application.secret = ""
      new_application.save
      expect(new_application.secret).not_to be_blank
    end

    it "generate secret on create unless one is set" do
      new_application.secret = secret
      new_application.save
      expect(new_application.secret).to eq(secret)
    end

    it "is invalid without secret" do
      new_application.save
      new_application.secret = nil
      expect(new_application).not_to be_valid
    end

    context "with hashing enabled" do
      include_context "with application hashing enabled"
      let(:app) { FactoryBot.create :application }
      let(:default_strategy) { Doorkeeper::SecretStoring::Sha256Hash }

      it "uses SHA256 to avoid additional dependencies" do
        # Ensure token was generated
        app.validate
        expect(app.secret).to eq(default_strategy.transform_secret(app.plaintext_secret))
      end

      context "when bcrypt strategy is configured" do
        # In this text context, we have bcrypt loaded so `bcrypt_present?`
        # will always be true
        before do
          Doorkeeper.configure do
            hash_application_secrets using: "Doorkeeper::SecretStoring::BCrypt"
          end
        end

        it "holds a volatile plaintext and BCrypt secret" do
          expect(app.secret_strategy).to eq Doorkeeper::SecretStoring::BCrypt
          expect(app.plaintext_secret).to be_a(String)
          expect(app.secret).not_to eq(app.plaintext_secret)
          expect { ::BCrypt::Password.create(app.secret) }.not_to raise_error
        end
      end

      it "does not fallback to plain lookup by default" do
        lookup = clazz.by_uid_and_secret(app.uid, app.secret)
        expect(lookup).to eq(nil)

        lookup = clazz.by_uid_and_secret(app.uid, app.plaintext_secret)
        expect(lookup).to eq(app)
      end

      context "with fallback enabled" do
        include_context "with token hashing and fallback lookup enabled"

        it "provides plain and hashed lookup" do
          lookup = clazz.by_uid_and_secret(app.uid, app.secret)
          expect(lookup).to eq(app)

          lookup = clazz.by_uid_and_secret(app.uid, app.plaintext_secret)
          expect(lookup).to eq(app)
        end
      end

      it "does not provide access to secret after loading" do
        lookup = clazz.by_uid_and_secret(app.uid, app.plaintext_secret)
        expect(lookup.plaintext_secret).to be_nil
      end
    end

    describe "destroy related models on cascade" do
      before(:each) do
        new_application.save
      end

      it "should destroy its access grants" do
        FactoryBot.create(:access_grant, application: new_application)
        expect { new_application.destroy }.to change { Doorkeeper::AccessGrant.count }.by(-1)
      end

      it "should destroy its access tokens" do
        FactoryBot.create(:access_token, application: new_application)
        FactoryBot.create(:access_token, application: new_application, revoked_at: Time.now.utc)
        expect do
          new_application.destroy
        end.to change { Doorkeeper::AccessToken.count }.by(-2)
      end
    end

    describe :ordered_by do
      let(:applications) { FactoryBot.create_list(:application, 5) }

      context "when a direction is not specified" do
        it "calls order with a default order of asc" do
          names = applications.map(&:name).sort
          expect(Application.ordered_by(:name).map(&:name)).to eq(names)
        end
      end

      context "when a direction is specified" do
        it "calls order with specified direction" do
          names = applications.map(&:name).sort.reverse
          expect(Application.ordered_by(:name, :desc).map(&:name)).to eq(names)
        end
      end
    end

    describe "#redirect_uri=" do
      context "when array of valid redirect_uris" do
        it "should join by newline" do
          new_application.redirect_uri = ["http://localhost/callback1", "http://localhost/callback2"]
          expect(new_application.redirect_uri).to eq("http://localhost/callback1\nhttp://localhost/callback2")
        end
      end
      context "when string of valid redirect_uris" do
        it "should store as-is" do
          new_application.redirect_uri = "http://localhost/callback1\nhttp://localhost/callback2"
          expect(new_application.redirect_uri).to eq("http://localhost/callback1\nhttp://localhost/callback2")
        end
      end
    end

    describe :authorized_for do
      let(:resource_owner) { double(:resource_owner, id: 10) }

      it "is empty if the application is not authorized for anyone" do
        expect(Application.authorized_for(resource_owner)).to be_empty
      end

      it "returns only application for a specific resource owner" do
        FactoryBot.create(:access_token, resource_owner_id: resource_owner.id + 1)
        token = FactoryBot.create(:access_token, resource_owner_id: resource_owner.id)
        expect(Application.authorized_for(resource_owner)).to eq([token.application])
      end

      it "excludes revoked tokens" do
        FactoryBot.create(:access_token, resource_owner_id: resource_owner.id, revoked_at: 2.days.ago)
        expect(Application.authorized_for(resource_owner)).to be_empty
      end

      it "returns all applications that have been authorized" do
        token1 = FactoryBot.create(:access_token, resource_owner_id: resource_owner.id)
        token2 = FactoryBot.create(:access_token, resource_owner_id: resource_owner.id)
        expect(Application.authorized_for(resource_owner)).to eq([token1.application, token2.application])
      end

      it "returns only one application even if it has been authorized twice" do
        application = FactoryBot.create(:application)
        FactoryBot.create(:access_token, resource_owner_id: resource_owner.id, application: application)
        FactoryBot.create(:access_token, resource_owner_id: resource_owner.id, application: application)
        expect(Application.authorized_for(resource_owner)).to eq([application])
      end
    end

    describe :revoke_tokens_and_grants_for do
      it "revokes all access tokens and access grants" do
        application_id = 42
        resource_owner = double
        expect(Doorkeeper::AccessToken)
          .to receive(:revoke_all_for).with(application_id, resource_owner)
        expect(Doorkeeper::AccessGrant)
          .to receive(:revoke_all_for).with(application_id, resource_owner)

        Application.revoke_tokens_and_grants_for(application_id, resource_owner)
      end
    end

    describe :by_uid_and_secret do
      context "when application is private/confidential" do
        it "finds the application via uid/secret" do
          app = FactoryBot.create :application
          authenticated = Application.by_uid_and_secret(app.uid, app.secret)
          expect(authenticated).to eq(app)
        end
        context "when secret is wrong" do
          it "should not find the application" do
            app = FactoryBot.create :application
            authenticated = Application.by_uid_and_secret(app.uid, "bad")
            expect(authenticated).to eq(nil)
          end
        end
      end

      context "when application is public/non-confidential" do
        context "when secret is blank" do
          it "should find the application" do
            app = FactoryBot.create :application, confidential: false
            authenticated = Application.by_uid_and_secret(app.uid, nil)
            expect(authenticated).to eq(app)
          end
        end
        context "when secret is wrong" do
          it "should not find the application" do
            app = FactoryBot.create :application, confidential: false
            authenticated = Application.by_uid_and_secret(app.uid, "bad")
            expect(authenticated).to eq(nil)
          end
        end
      end
    end

    describe :confidential? do
      subject { FactoryBot.create(:application, confidential: confidential).confidential? }

      context "when application is private/confidential" do
        let(:confidential) { true }
        it { expect(subject).to eq(true) }
      end

      context "when application is public/non-confidential" do
        let(:confidential) { false }
        it { expect(subject).to eq(false) }
      end
    end
  end
end
