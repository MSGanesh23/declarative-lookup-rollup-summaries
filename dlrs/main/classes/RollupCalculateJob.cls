/**
 * Copyright (c) 2013, Andrew Fawcett
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 *   are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *      this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright notice,
 *      this list of conditions and the following disclaimer in the documentation
 *      and/or other materials provided with the distribution.
 * - Neither the name of the Andrew Fawcett, nor the names of its contributors
 *      may be used to endorse or promote products derived from this software without
 *      specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 *  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 *  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 *  THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 *  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 *  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 *  OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **/

/**
 * Job recaculates a given rollup for all master records
 **/
public with sharing class RollupCalculateJob implements Database.Batchable<sObject> {
  private String lookupId;
  private String masterWhereClause;

  public RollupCalculateJob(String lookupId) {
    this.lookupId = lookupId;
  }

  public RollupCalculateJob(String lookupId, String masterWhereClause) {
    this.lookupId = lookupId;
    this.masterWhereClause = masterWhereClause;
  }

  public Database.QueryLocator start(Database.BatchableContext BC) {
    List<RollupSummary> lookups = new RollupSummariesSelector()
      .selectById(new Set<String>{ (String) lookupId });

    if (lookups.size() == 0) {
      throw RollupServiceException.rollupNotFound(lookupId);
    }

    RollupSummary lookup = lookups[0];

    if (
      Utilities.userHasCustomPermission(lookup.BypassCustPermApiName) ||
      BypassHandler.isBypassed(lookup.UniqueName)
    ) {
      System.debug('Rollup is disabled, will not execute ' + lookupId);
      // return an "empty" iteration so it doesn't run the execute method
      return Database.getQueryLocator(
        'SELECT Id FROM ' + lookup.ParentObject + ' LIMIT 0'
      );
    }

    // Query all the parent records as per the lookup definition
    return RollupService.masterRecordsAsQueryLocator(
      lookupId,
      masterWhereClause
    );
  }

  public void execute(
    Database.BatchableContext BC,
    List<sObject> masterRecords
  ) {
    try {
      // Update the master records as per the lookup definition
      RollupService.updateMasterRollups(
        new Set<String>{ lookupId },
        new Map<Id, Sobject>(masterRecords).keySet()
      );
    } catch (Exception e) {
      LookupRollupSummaryLog__c logEntry = new LookupRollupSummaryLog__c();
      List<RollupSummary> rollup = new RollupSummariesSelector()
        .selectById(new Set<String>{ lookupId });
      logEntry.ParentId__c = lookupId;
      if (!rollup.isEmpty()) {
        // Log the failure updating the master record for review
        logEntry.ParentObject__c = rollup[0]
          .Record.getSObjectType()
          .getDescribe()
          .getName();
      }

      logEntry.ErrorMessage__c =
        e.getMessage() +
        ' : ' +
        e.getStackTraceString();

      upsert logEntry ParentId__c;

      if (
        DeclarativeLookupRollupSummaries__c.getInstance()
          .DisableProblemEmails__c
      ) {
        // if emails are disabled then bail out
        return;
      }
      // Ids in scope
      List<String> ids = new List<String>();
      for (Id recordId : new Map<Id, SObject>(masterRecords).keySet()) {
        ids.add(recordId);
      }
      // Retrieve organization info to put in the email
      Organization org = [SELECT Id, Name FROM Organization];

      // Errors are emailed to the user that scheduled this job
      Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
      mail.setToAddresses(new List<String>{ UserInfo.getUserId() });
      mail.setSubject(
        String.format(
          'Apex job {0} failed to update rollups in {1} ({2})',
          new List<String>{ BC.getJobId(), org.Name, org.Id }
        )
      );
      mail.setPlainTextBody(
        String.format(
          'Error: {0}. Parent record Ids {1}',
          new List<String>{ e.getMessage(), String.join(ids, ',') }
        )
      );
      MessageService.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
    }
  }

  public void finish(Database.BatchableContext BC) {
    // Clear the Job Id which was preventing another calculate job running while this one was running
    RollupService.clearCalculateJobId(new Set<String>{ lookupId });
  }
}
