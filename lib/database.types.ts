export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type Database = {
  public: {
    Tables: {
      job_categories: {
        Row: {
          enabled: boolean;
          label: string;
          slug: string;
        };
        ComputedFields: never;
        Insert: {
          enabled?: boolean;
          label: string;
          slug: string;
        };
        Update: {
          enabled?: boolean;
          label?: string;
          slug?: string;
        };
        Relationships: [];
      };
      profiles: {
        Row: {
          availability: string | null;
          bio: string | null;
          business_location: string | null;
          business_name: string | null;
          campus_label: string | null;
          created_at: string;
          display_name: string | null;
          faculty_label: string | null;
          organisation_label: string | null;
          photo_key: string | null;
          skills: string[];
          updated_at: string;
          user_id: string;
        };
        ComputedFields: never;
        Insert: {
          availability?: string | null;
          bio?: string | null;
          business_location?: string | null;
          business_name?: string | null;
          campus_label?: string | null;
          created_at?: string;
          display_name?: string | null;
          faculty_label?: string | null;
          organisation_label?: string | null;
          photo_key?: string | null;
          skills?: string[];
          updated_at?: string;
          user_id: string;
        };
        Update: {
          availability?: string | null;
          bio?: string | null;
          business_location?: string | null;
          business_name?: string | null;
          campus_label?: string | null;
          created_at?: string;
          display_name?: string | null;
          faculty_label?: string | null;
          organisation_label?: string | null;
          photo_key?: string | null;
          skills?: string[];
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      can_receive_realtime_hint: {
        Args: { p_topic: string };
        Returns: boolean;
      };
      current_user_account_active: {
        Args: Record<PropertyKey, never>;
        Returns: boolean;
      };
      endorse_partner_verification: {
        Args: { p_statement: string; p_submission_id: string };
        Returns: Json;
      };
      get_my_identity_help_context: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
      get_my_identity_status: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
      get_my_verification_history: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
      register_my_identity: {
        Args: {
          p_account_type: string;
          p_age_confirmed: boolean;
          p_age_policy_version: string;
        };
        Returns: Json;
      };
      server_abandon_prestart_assignment_for_actor: {
        Args: {
          p_actor: string;
          p_assignment_id: string;
          p_idempotency_key: string;
          p_reason: string;
        };
        Returns: Json;
      };
      server_accept_application_for_actor: {
        Args: {
          p_actor: string;
          p_application_id: string;
          p_idempotency_key: string;
        };
        Returns: Json;
      };
      server_apply_to_job_for_actor: {
        Args: {
          p_actor: string;
          p_idempotency_key: string;
          p_job_id: string;
          p_note: string;
        };
        Returns: Json;
      };
      server_approve_case_decision_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_case_id: string;
          p_decision_version: number;
          p_expected_case_version: number;
          p_idempotency_key: string;
        };
        Returns: Json;
      };
      server_assign_case_appeal_reviewer_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_case_id: string;
          p_idempotency_key: string;
          p_reviewer_id: string;
        };
        Returns: Json;
      };
      server_assign_case_reviewer_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_case_id: string;
          p_idempotency_key: string;
          p_reviewer_id: string;
        };
        Returns: Json;
      };
      server_assign_verification_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_expected_assignment_id: string;
          p_reason: string;
          p_submission_id: string;
          p_target_reviewer: string;
        };
        Returns: Json;
      };
      server_authorize_case_file_download_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_case_id: string;
          p_evidence_number: number;
        };
        Returns: Json;
      };
      server_authorize_simulated_destination_change_for_actor: {
        Args: {
          p_actor: string;
          p_destination_id: string;
          p_expected_version: number;
          p_proof_sha256_hex: string;
          p_simulated_recipient_code: string;
        };
        Returns: Json;
      };
      server_authorize_withdrawal_for_actor: {
        Args: {
          p_actor: string;
          p_amount_kobo: string;
          p_destination_id: string;
          p_destination_version: number;
          p_proof_sha256_hex: string;
        };
        Returns: Json;
      };
      server_begin_school_challenge_for_actor: {
        Args: {
          p_actor: string;
          p_code_digest: string;
          p_email: string;
          p_request_key: string;
        };
        Returns: Json;
      };
      server_begin_verification_upload_for_actor: {
        Args: {
          p_actor: string;
          p_content_type: string;
          p_evidence_kind: string;
          p_evidence_position: number;
          p_size_bytes: number;
          p_submission_id: string;
          p_token_hash_hex: string;
        };
        Returns: Json;
      };
      server_cancel_unassigned_slots_for_actor: {
        Args: {
          p_actor: string;
          p_allocation_ids: string[];
          p_idempotency_key: string;
          p_job_id: string;
          p_reason: string;
        };
        Returns: Json;
      };
      server_case_appeal_command_for_actor: {
        Args: {
          p_action: string;
          p_actor: string;
          p_auth_aal: string;
          p_case_id: string;
          p_idempotency_key: string;
          p_payload: Json;
        };
        Returns: Json;
      };
      server_case_investigation_command_for_actor: {
        Args: {
          p_action: string;
          p_actor: string;
          p_auth_aal: string;
          p_case_id: string;
          p_idempotency_key: string;
          p_payload: Json;
        };
        Returns: Json;
      };
      server_claim_case_file_upload_for_actor: {
        Args: {
          p_actor: string;
          p_intent_id: string;
          p_token_hash_hex: string;
        };
        Returns: Json;
      };
      server_claim_notification_email_for_runner: {
        Args: { p_lease_seconds?: number; p_worker_id: string };
        Returns: Json;
      };
      server_claim_assignment_reminder_for_runner: {
        Args: { p_lease_seconds?: number; p_worker_id: string };
        Returns: Json;
      };
      server_dispatch_assignment_reminder_for_runner: {
        Args: { p_lease_token: string; p_reminder_id: string };
        Returns: Json;
      };
      server_fail_assignment_reminder_for_runner: {
        Args: {
          p_reminder_id: string;
          p_safe_error_code: string;
          p_lease_token: string;
        };
        Returns: Json;
      };
      server_authorize_notification_email_dispatch_for_runner: {
        Args: { p_delivery_id: string; p_lease_token: string };
        Returns: boolean;
      };
      server_claim_payment_operation_for_runner: {
        Args: { p_lease_seconds?: number; p_worker_id: string };
        Returns: Json;
      };
      server_claim_verification_upload_for_actor: {
        Args: {
          p_actor: string;
          p_intent_id: string;
          p_token_hash_hex: string;
        };
        Returns: Json;
      };
      server_complete_job_funding_operation_for_runner: {
        Args: {
          p_amount_kobo: string;
          p_client_reference: string;
          p_currency: string;
          p_fee_kobo: string;
          p_lease_token: string;
          p_merchant_identity: string;
          p_operation_id: string;
          p_provider_reference: string;
          p_result_sha256_hex: string;
          p_retry: boolean;
          p_safe_error_code: string;
          p_status: string;
        };
        Returns: Json;
      };
      server_complete_job_funding_settlement_for_runner: {
        Args: { p_operation_id: string; p_settlement_status: string };
        Returns: Json;
      };
      server_complete_job_funding_with_settlement_for_runner: {
        Args: {
          p_amount_kobo: string;
          p_client_reference: string;
          p_currency: string;
          p_fee_kobo: string;
          p_lease_token: string;
          p_merchant_identity: string;
          p_operation_id: string;
          p_provider_reference: string;
          p_result_sha256_hex: string;
          p_retry: boolean;
          p_safe_error_code: string;
          p_settlement_status: string;
          p_status: string;
        };
        Returns: Json;
      };
      server_complete_notification_email_for_runner: {
        Args: {
          p_delivery_id: string;
          p_lease_token: string;
          p_provider_capture_id?: string;
          p_safe_error_code?: string;
          p_status: string;
        };
        Returns: Json;
      };
      server_complete_payment_operation_for_runner: {
        Args: {
          p_fee_kobo: string;
          p_lease_token: string;
          p_operation_id: string;
          p_provider_reference: string;
          p_retry: boolean;
          p_safe_error_code: string;
          p_status: string;
        };
        Returns: Json;
      };
      server_complete_refund_operation_for_runner: {
        Args: {
          p_amount_kobo: string;
          p_client_reference: string;
          p_currency: string;
          p_fee_kobo: string;
          p_lease_token: string;
          p_operation_id: string;
          p_provider_reference: string;
          p_result_sha256_hex: string;
          p_retry: boolean;
          p_safe_error_code: string;
          p_settlement_status: string;
          p_source_provider_reference: string;
          p_status: string;
        };
        Returns: Json;
      };
      server_complete_worker_payout_for_runner: {
        Args: {
          p_amount_kobo: string;
          p_client_reference: string;
          p_currency: string;
          p_destination_id: string;
          p_destination_version: number;
          p_fee_kobo: string;
          p_lease_token: string;
          p_operation_id: string;
          p_provider_reference: string;
          p_result_sha256_hex: string;
          p_retry: boolean;
          p_safe_error_code: string;
          p_status: string;
        };
        Returns: Json;
      };
      server_confirm_completion_for_actor: {
        Args: {
          p_actor: string;
          p_assignment_id: string;
          p_idempotency_key: string;
        };
        Returns: Json;
      };
      server_confirm_school_challenge_for_actor: {
        Args: {
          p_actor: string;
          p_challenge_id: string;
          p_code_digest: string;
        };
        Returns: Json;
      };
      server_confirm_simulated_destination_change_for_actor: {
        Args: {
          p_actor: string;
          p_idempotency_key: string;
          p_proof_sha256_hex: string;
          p_simulated_recipient_code: string;
        };
        Returns: Json;
      };
      server_consent_prestart_cancellation_for_actor: {
        Args: {
          p_actor: string;
          p_cancellation_id: string;
          p_cancellation_version: number;
          p_idempotency_key: string;
          p_reason: string;
        };
        Returns: Json;
      };
      server_create_job_draft_for_actor: {
        Args: { p_actor: string; p_idempotency_key: string; p_terms: Json };
        Returns: Json;
      };
      server_discover_jobs_for_actor: {
        Args: {
          p_actor: string;
          p_cursor_created_at: string;
          p_cursor_job_id: string;
          p_filters: Json;
          p_limit: number;
        };
        Returns: Json;
      };
      server_fail_school_challenge_for_actor: {
        Args: { p_actor: string; p_challenge_id: string };
        Returns: Json;
      };
      server_finalize_case_file_upload_for_actor: {
        Args: {
          p_actor: string;
          p_content_type: string;
          p_intent_id: string;
          p_sha256_hex: string;
          p_size_bytes: number;
        };
        Returns: Json;
      };
      server_finalize_case_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_case_id: string;
          p_decision_version: number;
          p_expected_case_version: number;
          p_idempotency_key: string;
        };
        Returns: Json;
      };
      server_finalize_verification_upload_for_actor: {
        Args: {
          p_actor: string;
          p_content_type: string;
          p_intent_id: string;
          p_sha256_hex: string;
          p_size_bytes: number;
        };
        Returns: Json;
      };
      server_get_application_thread_for_actor: {
        Args: {
          p_actor: string;
          p_after_sequence: number;
          p_application_id: string;
          p_limit: number;
        };
        Returns: Json;
      };
      server_get_assignment_case_appeal_for_reviewer: {
        Args: { p_actor: string; p_auth_aal: string; p_case_id: string };
        Returns: Json;
      };
      server_get_assignment_case_for_actor: {
        Args: { p_actor: string; p_case_id: string };
        Returns: Json;
      };
      server_get_assignment_case_for_reviewer: {
        Args: { p_actor: string; p_auth_aal: string; p_case_id: string };
        Returns: Json;
      };
      server_get_assignment_status_for_actor: {
        Args: { p_actor: string; p_assignment_id: string };
        Returns: Json;
      };
      server_get_discoverable_job_detail_for_actor: {
        Args: { p_actor: string; p_job_id: string };
        Returns: Json;
      };
      server_get_job_applications_for_actor: {
        Args: {
          p_actor: string;
          p_cursor_application_id: string;
          p_cursor_applied_at: string;
          p_job_id: string;
          p_limit: number;
        };
        Returns: Json;
      };
      server_get_job_funding_status_for_actor: {
        Args: { p_actor: string; p_job_id: string };
        Returns: Json;
      };
      server_get_my_applications_for_actor: {
        Args: {
          p_actor: string;
          p_cursor_application_id: string;
          p_cursor_applied_at: string;
          p_limit: number;
        };
        Returns: Json;
      };
      server_get_my_funded_job_detail_for_actor: {
        Args: { p_actor: string; p_job_id: string };
        Returns: Json;
      };
      server_get_my_funded_job_history: {
        Args: {
          p_actor: string;
          p_cursor_created_at: string;
          p_cursor_job_id: string;
          p_limit: number;
        };
        Returns: Json;
      };
      server_get_my_wallet_for_actor: {
        Args: {
          p_actor: string;
          p_before_created_at: string;
          p_before_id: string;
        };
        Returns: Json;
      };
      server_get_realtime_topic_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_resource: string;
          p_scope: string;
        };
        Returns: Json;
      };
      server_get_safe_profile_for_viewer: {
        Args: { p_subject: string; p_viewer: string };
        Returns: Json;
      };
      server_hide_assignment_review_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_idempotency_key: string;
          p_reason: string;
          p_review_id: string;
        };
        Returns: Json;
      };
      server_get_verification_download_for_actor: {
        Args: { p_actor: string; p_auth_aal: string; p_evidence_id: string };
        Returns: Json;
      };
      server_inspect_financial_reference_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_reference_type: string;
          p_reference_value: string;
        };
        Returns: Json;
      };
      server_issue_case_file_upload_for_actor: {
        Args: {
          p_actor: string;
          p_case_id: string;
          p_content_type: string;
          p_idempotency_key: string;
          p_request_number: number;
          p_size_bytes: number;
          p_token_hash_hex: string;
        };
        Returns: Json;
      };
      server_list_assignment_case_appeal_queue_for_actor: {
        Args: { p_actor: string; p_auth_aal: string; p_limit: number };
        Returns: Json;
      };
      server_list_assignment_case_queue_for_actor: {
        Args: { p_actor: string; p_auth_aal: string; p_limit: number };
        Returns: Json;
      };
      server_list_my_notifications_for_actor: {
        Args: {
          p_actor: string;
          p_before_created_at?: string;
          p_before_id?: string;
        };
        Returns: Json;
      };
      server_list_notification_delivery_attention_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_before_delivery_id?: string;
          p_before_updated_at?: string;
        };
        Returns: Json;
      };
      server_list_profile_reviews_for_viewer: {
        Args: {
          p_before_created_at?: string | null;
          p_before_review_id?: string | null;
          p_subject: string;
          p_viewer: string;
        };
        Returns: Json;
      };
      server_list_review_moderation_queue_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_before_reported_at?: string | null;
          p_before_review_id?: string | null;
          p_limit?: number;
        };
        Returns: Json;
      };
      server_list_verification_assignment_candidates_for_actor: {
        Args: { p_actor: string; p_auth_aal: string };
        Returns: Json;
      };
      server_list_verification_orphans_for_cleanup: {
        Args: { p_before: string; p_candidate_keys: string[] };
        Returns: string[];
      };
      server_list_verification_queue_for_actor: {
        Args: { p_actor: string; p_auth_aal: string };
        Returns: Json;
      };
      server_mark_application_thread_read_for_actor: {
        Args: {
          p_actor: string;
          p_last_read_sequence: number;
          p_thread_id: string;
        };
        Returns: Json;
      };
      server_mark_my_notification_read_for_actor: {
        Args: { p_actor: string; p_notification_id: string };
        Returns: Json;
      };
      server_open_assignment_hold_for_actor:
        | {
            Args: {
              p_actor: string;
              p_assignment_id: string;
              p_desired_outcome: string;
              p_follow_up: string;
              p_idempotency_key: string;
              p_narrative: string;
              p_reason_code: string;
            };
            Returns: Json;
          }
        | {
            Args: {
              p_actor: string;
              p_assignment_id: string;
              p_desired_outcome: string;
              p_idempotency_key: string;
              p_narrative: string;
              p_reason_code: string;
            };
            Returns: Json;
          };
      server_process_case_appeal_receipt_for_actor: {
        Args: { p_actor: string; p_appeal_id: string; p_auth_aal: string };
        Returns: Json;
      };
      server_propose_case_decision_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_case_id: string;
          p_expected_case_version: number;
          p_idempotency_key: string;
          p_payload: Json;
        };
        Returns: Json;
      };
      server_reconcile_financial_state_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_simulator_cash_kobo: string;
          p_simulator_receivable_kobo: string;
        };
        Returns: Json;
      };
      server_record_case_appeal_receipt_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_case_id: string;
          p_idempotency_key: string;
          p_statement: string;
        };
        Returns: Json;
      };
      server_record_job_funding_initialization: {
        Args: { p_operation_id: string; p_provider_reference: string };
        Returns: Json;
      };
      server_record_job_funding_unknown_for_actor: {
        Args: { p_actor: string; p_operation_id: string };
        Returns: Json;
      };
      server_record_payment_simulator_receipt: {
        Args: {
          p_client_reference: string;
          p_event_reference: string;
          p_payload_sha256_hex: string;
          p_provider_reference: string;
        };
        Returns: Json;
      };
      server_record_verification_download_access_for_actor: {
        Args: { p_actor: string; p_evidence_id: string; p_object_key: string };
        Returns: Json;
      };
      server_register_identity_for_actor: {
        Args: {
          p_account_type: string;
          p_actor: string;
          p_age_confirmed: boolean;
          p_age_policy_version: string;
        };
        Returns: Json;
      };
      server_reject_application_for_actor: {
        Args: {
          p_actor: string;
          p_application_id: string;
          p_idempotency_key: string;
        };
        Returns: Json;
      };
      server_reject_case_file_upload_for_actor: {
        Args: { p_actor: string; p_intent_id: string; p_reason_code: string };
        Returns: Json;
      };
      server_reject_verification_upload_for_actor: {
        Args: { p_actor: string; p_intent_id: string; p_reason_code: string };
        Returns: Json;
      };
      server_request_prestart_cancellation_for_actor: {
        Args: {
          p_actor: string;
          p_assignment_id: string;
          p_idempotency_key: string;
          p_reason: string;
        };
        Returns: Json;
      };
      server_request_withdrawal_for_actor: {
        Args: {
          p_actor: string;
          p_amount_kobo: string;
          p_destination_id: string;
          p_destination_version: number;
          p_expected_provider_fee_kobo: string;
          p_idempotency_key: string;
          p_proof_sha256_hex: string;
        };
        Returns: Json;
      };
      server_reserve_phone_sms_send_for_actor: {
        Args: { p_actor: string; p_phone_digest: string; p_request_id: string };
        Returns: boolean;
      };
      server_review_verification_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_decision: string;
          p_expected_decision_version: number;
          p_expected_status: string;
          p_expected_version: number;
          p_idempotency_key: string;
          p_reason: string;
          p_submission_id: string;
        };
        Returns: Json;
      };
      server_report_assignment_review_for_actor: {
        Args: { p_actor: string; p_review_id: string };
        Returns: Json;
      };
      server_send_application_message_for_actor: {
        Args: {
          p_actor: string;
          p_body: string;
          p_client_message_id: string;
          p_thread_id: string;
        };
        Returns: Json;
      };
      server_set_identity_suspension_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_idempotency_key: string;
          p_reason: string;
          p_subject: string;
          p_suspended: boolean;
        };
        Returns: Json;
      };
      server_signoff_case_decision_nonresponse_for_actor: {
        Args: {
          p_actor: string;
          p_auth_aal: string;
          p_case_id: string;
          p_decision_version: number;
          p_expected_case_version: number;
          p_idempotency_key: string;
          p_substantive_reasoning: string;
        };
        Returns: Json;
      };
      server_start_assignment_for_actor: {
        Args: {
          p_actor: string;
          p_assignment_id: string;
          p_idempotency_key: string;
        };
        Returns: Json;
      };
      server_start_job_funding_for_actor: {
        Args: {
          p_actor: string;
          p_expected_terms_version: number;
          p_idempotency_key: string;
          p_job_id: string;
        };
        Returns: Json;
      };
      server_submit_assignment_for_actor: {
        Args: {
          p_actor: string;
          p_assignment_id: string;
          p_idempotency_key: string;
        };
        Returns: Json;
      };
      server_submit_assignment_review_for_actor: {
        Args: {
          p_actor: string;
          p_assignment_id: string;
          p_idempotency_key: string;
          p_rating: number;
          p_review_text: string | null;
        };
        Returns: Json;
      };
      server_update_job_draft_for_actor: {
        Args: {
          p_actor: string;
          p_expected_terms_version: number;
          p_idempotency_key: string;
          p_job_id: string;
          p_terms: Json;
        };
        Returns: Json;
      };
      server_update_profile_for_actor: {
        Args: { p_actor: string; p_profile: Json };
        Returns: Json;
      };
      server_withdraw_application_for_actor: {
        Args: {
          p_actor: string;
          p_application_id: string;
          p_idempotency_key: string;
        };
        Returns: Json;
      };
      submit_my_verification: {
        Args: {
          p_connection_type: string;
          p_idempotency_key: string;
          p_legal_name: string;
          p_narrative: string;
        };
        Returns: Json;
      };
    };
    Enums: {
      [_ in never]: never;
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
};

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">;

type DefaultSchema = DatabaseWithoutInternals[Extract<
  keyof Database,
  "public"
>];

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R;
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R;
      }
      ? R
      : never
    : never;

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema["Tables"] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I;
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I;
      }
      ? I
      : never
    : never;

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema["Tables"] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U;
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U;
      }
      ? U
      : never
    : never;

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    keyof DefaultSchema["Enums"] | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never;

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never;

export const Constants = {
  public: {
    Enums: {},
  },
} as const;
