# FK orphan scan

Generated 2026-05-15T20:28:50+01:00. Read-only.

Checks every FK in the schema for child rows whose foreign key points at a non-existent parent row.

| child | fk col | parent | pk col | orphan count | delete rule |
|---|---|---|---|---|---|
| public.accommodation_bookings | email_id | public.emails | id | 0  | NO ACTION |
| public.accommodation_daily | email_id | public.emails | id | 0  | NO ACTION |
| public.accommodation_daily_reports | source_email_id | public.emails | id | 0  | NO ACTION |
| public.account_property_map | entity_id | public.entities | id | 0  | NO ACTION |
| public.account_property_map | property_id | public.properties | id | 0  | NO ACTION |
| public.account_transfers | dst_txn_id | public.bank_transactions | id | 0  | NO ACTION |
| public.account_transfers | src_txn_id | public.bank_transactions | id | 0  | NO ACTION |
| public.ai_builder_temporary_workflow | threadId | public.instance_ai_threads | id | 0  | CASCADE |
| public.ai_builder_temporary_workflow | workflowId | public.workflow_entity | id | 0  | CASCADE |
| public.ai_usage | entity_id | public.entities | id | 0  | NO ACTION |
| public.audit_log | entity_id | public.entities | id | 0  | NO ACTION |
| public.auth_identity | userId | public.user | id | 0  | NO ACTION |
| public.bank_accounts | entity_id | public.entities | id | 0  | NO ACTION |
| public.bank_transactions | bank_account_id | public.bank_accounts | id | 0  | NO ACTION |
| public.bank_transactions | entity_id | public.entities | id | 0  | NO ACTION |
| public.benchmark_results | model_name | public.model_registry | model_name | 0  | NO ACTION |
| public.bot_feedback | email_id | public.emails | id | 0  | SET NULL |
| public.bot_feedback | invoice_id | public.vendor_invoice_inbox | id | 0  | SET NULL |
| public.card_statements | bank_account_id | public.bank_accounts | id | 0  | NO ACTION |
| public.card_statements | entity_id | public.entities | id | 0  | NO ACTION |
| public.cashflow_forecast | entity_id | public.entities | id | 0  | NO ACTION |
| public.caterbook_daily_snapshots | email_report_id | public.caterbook_email_reports | id | 0  | CASCADE |
| public.caterbook_observations | email_report_id | public.caterbook_email_reports | id | 0  | CASCADE |
| public.chat_hub_agent_tools | agentId | public.chat_hub_agents | id | 0  | CASCADE |
| public.chat_hub_agent_tools | toolId | public.chat_hub_tools | id | 0  | CASCADE |
| public.chat_hub_agents | credentialId | public.credentials_entity | id | 0  | SET NULL |
| public.chat_hub_agents | ownerId | public.user | id | 0  | CASCADE |
| public.chat_hub_messages | agentId | public.chat_hub_agents | id | 0  | SET NULL |
| public.chat_hub_messages | executionId | public.execution_entity | id | 0  | SET NULL |
| public.chat_hub_messages | previousMessageId | public.chat_hub_messages | id | 0  | CASCADE |
| public.chat_hub_messages | retryOfMessageId | public.chat_hub_messages | id | 0  | CASCADE |
| public.chat_hub_messages | revisionOfMessageId | public.chat_hub_messages | id | 0  | CASCADE |
| public.chat_hub_messages | sessionId | public.chat_hub_sessions | id | 0  | CASCADE |
| public.chat_hub_messages | workflowId | public.workflow_entity | id | 0  | SET NULL |
| public.chat_hub_session_tools | sessionId | public.chat_hub_sessions | id | 0  | CASCADE |
| public.chat_hub_session_tools | toolId | public.chat_hub_tools | id | 0  | CASCADE |
| public.chat_hub_sessions | agentId | public.chat_hub_agents | id | 0  | SET NULL |
| public.chat_hub_sessions | credentialId | public.credentials_entity | id | 0  | SET NULL |
| public.chat_hub_sessions | ownerId | public.user | id | 0  | CASCADE |
| public.chat_hub_sessions | workflowId | public.workflow_entity | id | 0  | SET NULL |
| public.chat_hub_tools | ownerId | public.user | id | 0  | CASCADE |
| public.child_events | child_id | public.children | id | 0  | NO ACTION |
| public.child_events | source_email_id | public.emails | id | 0  | NO ACTION |
| public.clover_batches | entity_id | public.entities | id | 0  | NO ACTION |
| public.clover_batches | source_document_id | public.documents | id | 0  | NO ACTION |
| public.companies_house_alerts | entity_id | public.entities | id | 0  | NO ACTION |
| public.credential_dependency | credentialId | public.credentials_entity | id | 0  | CASCADE |
| public.credentials_entity | resolverId | public.dynamic_credential_resolver | id | 0  | SET NULL |
| public.data_table | projectId | public.project | id | 0  | CASCADE |
| public.data_table_column | dataTableId | public.data_table | id | 0  | CASCADE |
| public.document_versions | document_id | public.documents | id | 0  | NO ACTION |
| public.documents | entity_id | public.entities | id | 0  | NO ACTION |
| public.dojo_transactions | entity_id | public.entities | id | 0  | NO ACTION |
| public.due_date_extractions | invoice_id | public.vendor_invoice_inbox | id | 0  | CASCADE |
| public.dynamic_credential_entry | credential_id | public.credentials_entity | id | 0  | CASCADE |
| public.dynamic_credential_entry | resolver_id | public.dynamic_credential_resolver | id | 0  | CASCADE |
| public.dynamic_credential_user_entry | credentialId | public.credentials_entity | id | 0  | CASCADE |
| public.dynamic_credential_user_entry | resolverId | public.dynamic_credential_resolver | id | 0  | CASCADE |
| public.dynamic_credential_user_entry | userId | public.user | id | 0  | CASCADE |
| public.email_attachments | email_id | public.emails | id | 0  | NO ACTION |
| public.email_tasks | email_id | public.emails | id | 0  | CASCADE |
| public.emails | entity_id | public.entities | id | 0  | NO ACTION |
| public.epos_daily | email_id | public.emails | id | 0  | NO ACTION |
| public.epos_daily_reports | source_email_id | public.emails | id | 0  | NO ACTION |
| public.events | entity_id | public.entities | id | 0  | NO ACTION |
| public.events_2026_04 | entity_id | public.entities | id | 0  | NO ACTION |
| public.events_2026_05 | entity_id | public.entities | id | 0  | NO ACTION |
| public.events_2026_06 | entity_id | public.entities | id | 0  | NO ACTION |
| public.events_2026_07 | entity_id | public.entities | id | 0  | NO ACTION |
| public.events_overflow | entity_id | public.entities | id | 0  | NO ACTION |
| public.execution_annotation_tags | annotationId | public.execution_annotations | id | 0  | CASCADE |
| public.execution_annotation_tags | tagId | public.annotation_tag_entity | id | 0  | CASCADE |
| public.execution_annotations | executionId | public.execution_entity | id | 0  | CASCADE |
| public.execution_data | executionId | public.execution_entity | id | 0  | CASCADE |
| public.execution_entity | workflowId | public.workflow_entity | id | 0  | CASCADE |
| public.execution_metadata | executionId | public.execution_entity | id | 0  | CASCADE |
| public.folder | parentFolderId | public.folder | id | 0  | CASCADE |
| public.folder | projectId | public.project | id | 0  | CASCADE |
| public.folder_tag | folderId | public.folder | id | 0  | CASCADE |
| public.folder_tag | tagId | public.tag_entity | id | 0  | CASCADE |
| public.holiday_entitlement | staff_id | public.staff | id | 0  | NO ACTION |
| public.holiday_requests | staff_id | public.staff | id | 0  | NO ACTION |
| public.insights_by_period | metaId | public.insights_metadata | metaId | 0  | CASCADE |
| public.insights_metadata | projectId | public.project | id | 0  | SET NULL |
| public.insights_metadata | workflowId | public.workflow_entity | id | 0  | SET NULL |
| public.insights_raw | metaId | public.insights_metadata | metaId | 0  | CASCADE |
| public.installed_nodes | package | public.installed_packages | packageName | 0  | CASCADE |
| public.instance_ai_iteration_logs | threadId | public.instance_ai_threads | id | 0  | CASCADE |
| public.instance_ai_messages | threadId | public.instance_ai_threads | id | 0  | CASCADE |
| public.instance_ai_observational_memory | threadId | public.instance_ai_threads | id | 0  | SET NULL |
| public.instance_ai_run_snapshots | threadId | public.instance_ai_threads | id | 0  | CASCADE |
| public.invoice_feedback | invoice_id | public.vendor_invoice_inbox | id | 0  | CASCADE |
| public.invoices | entity_id | public.entities | id | 0  | NO ACTION |
| public.medical_history | child_id | public.children | id | 0  | NO ACTION |
| public.medical_history | source_email_id | public.emails | id | 0  | NO ACTION |
| public.model_recommendations | current_model | public.model_registry | model_name | 0  | NO ACTION |
| public.model_recommendations | recommended_model | public.model_registry | model_name | 0  | NO ACTION |
| public.model_scores | model_name | public.model_registry | model_name | 0  | NO ACTION |
| public.mortgage_accounts | borrower_entity_id | public.entities | id | 0  | NO ACTION |
| public.mortgage_statement_periods | document_id | public.documents | id | 0  | NO ACTION |
| public.mortgage_statement_periods | mortgage_account_id | public.mortgage_accounts | id | 0  | CASCADE |
| public.oauth_access_tokens | clientId | public.oauth_clients | id | 0  | CASCADE |
| public.oauth_access_tokens | userId | public.user | id | 0  | CASCADE |
| public.oauth_authorization_codes | clientId | public.oauth_clients | id | 0  | CASCADE |
| public.oauth_authorization_codes | userId | public.user | id | 0  | CASCADE |
| public.oauth_refresh_tokens | clientId | public.oauth_clients | id | 0  | CASCADE |
| public.oauth_refresh_tokens | userId | public.user | id | 0  | CASCADE |
| public.oauth_user_consents | clientId | public.oauth_clients | id | 0  | CASCADE |
| public.oauth_user_consents | userId | public.user | id | 0  | CASCADE |
| public.processed_data | workflowId | public.workflow_entity | id | 0  | CASCADE |
| public.product_alias | canonical_id | public.product_canonical | id | 0  | CASCADE |
| public.product_aliases | canonical_id | public.product_canonical | id | 0  | CASCADE |
| public.project | creatorId | public.user | id | 0  | SET NULL |
| public.project_relation | projectId | public.project | id | 0  | CASCADE |
| public.project_relation | role | public.role | slug | 0  | NO ACTION |
| public.project_relation | userId | public.user | id | 0  | CASCADE |
| public.project_secrets_provider_access | projectId | public.project | id | 0  | CASCADE |
| public.project_secrets_provider_access | secretsProviderConnectionId | public.secrets_provider_connection | id | 0  | CASCADE |
| public.properties | entity_id | public.entities | id | 0  | NO ACTION |
| public.property_compliance | property_id | public.properties | id | 0  | NO ACTION |
| public.property_market_log | property_id | public.properties | id | 0  | CASCADE |
| public.property_mortgage_accounts | mortgage_account_id | public.mortgage_accounts | id | 0  | CASCADE |
| public.property_mortgage_accounts | property_id | public.properties | id | 0  | NO ACTION |
| public.recipe_components | product_canonical_id | public.product_canonical | id | 0  | NO ACTION |
| public.recipe_components | recipe_id | public.recipes | id | 0  | CASCADE |
| public.reconciliation_flags | bank_transaction_id | public.bank_transactions | id | 0  | NO ACTION |
| public.reconciliation_flags | entity_id | public.entities | id | 0  | NO ACTION |
| public.rent_payments | bank_transaction_id | public.bank_transactions | id | 0  | NO ACTION |
| public.rent_payments | entity_id | public.entities | id | 0  | NO ACTION |
| public.rent_payments | tenancy_id | public.tenancies | id | 0  | NO ACTION |
| public.review_drafts | source | public.guest_reviews | source | 0  | CASCADE |
| public.role_mapping_rule | role | public.role | slug | 0  | CASCADE |
| public.role_mapping_rule_project | projectId | public.project | id | 0  | CASCADE |
| public.role_mapping_rule_project | roleMappingRuleId | public.role_mapping_rule | id | 0  | CASCADE |
| public.role_scope | roleSlug | public.role | slug | 0  | CASCADE |
| public.role_scope | scopeSlug | public.scope | slug | 0  | CASCADE |
| public.shared_credentials | credentialsId | public.credentials_entity | id | 0  | CASCADE |
| public.shared_credentials | projectId | public.project | id | 0  | CASCADE |
| public.shared_workflow | projectId | public.project | id | 0  | CASCADE |
| public.shared_workflow | workflowId | public.workflow_entity | id | 0  | CASCADE |
| public.staff | entity_id | public.entities | id | 0  | NO ACTION |
| public.static_context | entity_id | public.entities | id | 0  | NO ACTION |
| public.supplier_invoice_history | entity_id | public.entities | id | 0  | NO ACTION |
| public.tenancies | property_id | public.properties | id | 0  | NO ACTION |
| public.test_case_execution | executionId | public.execution_entity | id | 0  | SET NULL |
| public.test_case_execution | testRunId | public.test_run | id | 0  | CASCADE |
| public.test_run | workflowId | public.workflow_entity | id | 0  | CASCADE |
| public.training_records | staff_id | public.staff | id | 0  | NO ACTION |
| public.trusted_key | sourceId | public.trusted_key_source | id | 0  | CASCADE |
| public.user | roleSlug | public.role | slug | 0  | NO ACTION |
| public.user_api_keys | userId | public.user | id | 0  | CASCADE |
| public.user_favorites | userId | public.user | id | 0  | CASCADE |
| public.variables | projectId | public.project | id | 0  | CASCADE |
| public.vat_returns_log | entity_id | public.entities | id | 0  | NO ACTION |
| public.vendor_invoice_lines | canonical_id | public.product_canonical | id | 0  | NO ACTION |
| public.vendor_invoice_lines | invoice_id | public.vendor_invoice_inbox | id | 0  | CASCADE |
| public.webhook_entity | workflowId | public.workflow_entity | id | 0  | CASCADE |
| public.workflow_builder_session | userId | public.user | id | 0  | CASCADE |
| public.workflow_builder_session | workflowId | public.workflow_entity | id | 0  | CASCADE |
| public.workflow_dependency | workflowId | public.workflow_entity | id | 0  | CASCADE |
| public.workflow_entity | activeVersionId | public.workflow_history | versionId | 0  | RESTRICT |
| public.workflow_entity | parentFolderId | public.folder | id | 0  | CASCADE |
| public.workflow_history | workflowId | public.workflow_entity | id | 0  | CASCADE |
| public.workflow_publish_history | userId | public.user | id | 0  | SET NULL |
| public.workflow_publish_history | versionId | public.workflow_history | versionId | 0  | SET NULL |
| public.workflow_publish_history | workflowId | public.workflow_entity | id | 0  | CASCADE |
| public.workflow_published_version | publishedVersionId | public.workflow_history | versionId | 0  | RESTRICT |
| public.workflow_published_version | workflowId | public.workflow_entity | id | 0  | RESTRICT |
| public.workflows_tags | tagId | public.tag_entity | id | 0  | CASCADE |
| public.workflows_tags | workflowId | public.workflow_entity | id | 0  | CASCADE |
| raw.bank_lines | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_01 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_01 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_02 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_02 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_03 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_03 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_04 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_04 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_05 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_06 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_06 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_07 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_07 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_08 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_08 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_09 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_09 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_10 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_10 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_11 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_11 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2019_12 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2019_12 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_01 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_01 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_02 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_02 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_03 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_03 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_04 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_04 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_05 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_06 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_06 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_07 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_07 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_08 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_08 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_09 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_09 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_10 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_10 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_11 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_11 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2020_12 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2020_12 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_01 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_01 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_02 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_02 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_03 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_03 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_04 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_04 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_05 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_06 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_06 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_07 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_07 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_08 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_08 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_09 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_09 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_10 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_10 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_11 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_11 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2021_12 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2021_12 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_01 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_01 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_02 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_02 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_03 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_03 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_04 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_04 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_05 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_06 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_06 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_07 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_07 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_08 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_08 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_09 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_09 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_10 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_10 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_11 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_11 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2022_12 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2022_12 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_01 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_01 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_02 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_02 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_03 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_03 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_04 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_04 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_05 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_06 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_06 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_07 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_07 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_08 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_08 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_09 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_09 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_10 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_10 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_11 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_11 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2023_12 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2023_12 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_01 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_01 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_02 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_02 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_03 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_03 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_04 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_04 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_05 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_06 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_06 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_07 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_07 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_08 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_08 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_09 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_09 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_10 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_10 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_11 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_11 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2024_12 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2024_12 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_01 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_01 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_02 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_02 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_03 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_03 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_04 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_04 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_05 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_06 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_06 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_07 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_07 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_08 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_08 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_09 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_09 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_10 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_10 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_11 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_11 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2025_12 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2025_12 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2026_01 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2026_01 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2026_02 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2026_02 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2026_03 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2026_03 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2026_04 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2026_04 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.bank_lines_2026_05 | entity_id | public.entities | id | 0  | NO ACTION |
| raw.bank_lines_2026_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.caterbook_reservations | import_id | raw.imports | id | 0  | NO ACTION |
| raw.caterbook_reservations_2026_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.clover_transactions | import_id | raw.imports | id | 0  | NO ACTION |
| raw.clover_transactions_2026_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.dojo_transactions | import_id | raw.imports | id | 0  | NO ACTION |
| raw.dojo_transactions_2026_01 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.dojo_transactions_2026_02 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.dojo_transactions_2026_03 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.dojo_transactions_2026_04 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.dojo_transactions_2026_05 | import_id | raw.imports | id | 0  | NO ACTION |
| raw.touchoffice_orders | import_id | raw.imports | id | 0  | NO ACTION |
| raw.touchoffice_orders_2026_05 | import_id | raw.imports | id | 0  | NO ACTION |
| staging.bank_lines | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_01 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_02 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_03 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_04 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_05 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_06 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_07 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_08 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_09 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_10 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_11 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2019_12 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_01 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_02 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_03 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_04 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_05 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_06 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_07 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_08 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_09 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_10 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_11 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2020_12 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_01 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_02 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_03 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_04 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_05 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_06 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_07 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_08 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_09 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_10 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_11 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2021_12 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_01 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_02 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_03 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_04 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_05 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_06 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_07 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_08 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_09 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_10 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_11 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2022_12 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_01 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_02 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_03 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_04 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_05 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_06 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_07 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_08 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_09 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_10 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_11 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2023_12 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_01 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_02 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_03 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_04 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_05 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_06 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_07 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_08 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_09 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_10 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_11 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2024_12 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_01 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_02 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_03 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_04 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_05 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_06 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_07 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_08 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_09 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_10 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_11 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2025_12 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2026_01 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2026_02 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2026_03 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2026_04 | entity_id | public.entities | id | 0  | NO ACTION |
| staging.bank_lines_2026_05 | entity_id | public.entities | id | 0  | NO ACTION |

## Summary

- Total FK constraints checked: 452
- Clean (0 orphans): 452
- Total orphaned rows across all FKs: 0
