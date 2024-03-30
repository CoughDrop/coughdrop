class AddOrganizationExpiresAtToUsers < ActiveRecord::Migration[5.0]
  def change
    add_column :users, :organization_expires_at, :datetime
  end
end
