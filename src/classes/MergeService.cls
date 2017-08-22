global with sharing class MergeService {

    
    /**
     * A singleton instance of the service
     */
    public static Map<String, MergeService> instancesByName =
            new Map<String, MergeService>();

    /**
     * The list of merge concerns which are considered by this instance
     */
    private List<MergeConcern__mdt> concerns { get; set; }

    /**
     * The full API name for the object managed by this merge service.
     * As of API 40.0 the only supported objects are Lead, Account and Contact.
     */
    private String sobjectName { get; set; }
    private String sobjectNameOriginal { get; set; } // added by danhowellnz

    /**
     * Remember the object name for the merge service
     *
     * @param 
     */
    public MergeService(String sobjectName) {
        this.sobjectName = sobjectName;
        this.sobjectNameOriginal = sobjectName;
            
        this.concerns = [
            SELECT Id, FieldName__c, IsForceOverwrite__c
            FROM MergeConcern__mdt
            WHERE SobjectName__c = :sobjectName
        ];
        // If it's person account switch the sobject name back to accounts
        // by having them seperate it allows each to have seperate concerns saved in the custom metadata
        // added by danhowellnz
        if(sobjectName == 'PersonAccount'){
            this.sobjectName = 'Account';
        }
        
        
    }

    /**
     * @return the matching records, with all fields required to evaluate
     *         and manage merge concerns
     */
    private String getQuery() {

        // Compile a list of the field names for merge concerns
        List<String> fieldNames = new List<String> { 'Id' };

        for (MergeConcern__mdt eachConcern : this.concerns) {
            fieldNames.add(eachConcern.FieldName__c);
        }

        String selectClause = 'SELECT ' + String.join(fieldNames, ', ');

        // Return the fully constructed SOQL statement
        return String.join(new List<String> {
            selectClause,
            'FROM '+sobjectName,
            'WHERE Id IN :recordIds'
        }, ' ');
    }

   

    
    
    
    
    /**
     * @param masterRecord
     * @param mergedRecord
     */
    public void mergeOne(Sobject masterRecord, Sobject mergedRecord) {
        for (MergeConcern__mdt eachConcern : this.concerns) {

            // If a field is enumerated in the custom metadata, this implies
            // that the value from the merged record is of some value.
            // The default behavior is to overwrite-if-blank, unless the
            // Force Overwrite checkbox is checked.
            if (eachConcern.IsForceOverwrite__c
                    || masterRecord.get(eachConcern.FieldName__c) == null) {

                // Keep the value from the merged record
                masterRecord.put(eachConcern.FieldName__c,
                        mergedRecord.get(eachConcern.FieldName__c));
            }
        }
        

        List<Sobject> mergeParameters =
                (List<Sobject>)this.getSobjectListType().newInstance();
        
        mergeParameters.addAll(new List<Sobject> {
            masterRecord,
            mergedRecord
        });

       //update campaign members before merge
       ////added by danhowellnz
       //Not working for lead merges yet
       if(sobjectNameOriginal == 'Contact' || sobjectNameOriginal == 'PersonAccount' ){
           system.debug('Campaign member update attempted');
            try{
            updatecampaignmembers(masterRecord,mergedRecord);
            }catch(exception e){system.debug('error in updatecampaignmembers: ' +e);}
       }
       
        system.debug('merge attempted');
        Database.merge(mergeParameters[0], mergeParameters[1]);

        
        // save a datetime of the last merge to the object
        // Needs a custom field called: LastMerged__c
        // added by danhowellnz
        try{
          mergeParameters[0].put('LastMerged__c', system.now() );
          update mergeParameters[0];
        }catch(exception e){system.debug('error on updating lastmerged__c '+e);}
        
    }
    
    
    
    
    
    //************************** updatecampaignmembers *********************************
    
    public void updatecampaignmembers(Sobject masterRecord, Sobject mergedRecord) {
  
              
         //Get fields to merge from concern metadata
         List<MergeConcern__mdt> concernscampaignmembers = [
            SELECT Id, FieldName__c, IsForceOverwrite__c
            FROM MergeConcern__mdt
            WHERE SobjectName__c = 'CampaignMember'
        ];
        List<String> fieldNames = new List<String> { 'Id','campaignid','contactid' };
        for (MergeConcern__mdt eachConcern : concernscampaignmembers) {
            fieldNames.add(eachConcern.FieldName__c);
        }
        String selectfields = String.join(fieldNames, ', ');
            
        
                
        //Get contact id for old records. THese are the masterRecord as the old records are deleted and merged to the newest.
        ID masterRecordcontactId = null;
        if(sobjectNameOriginal == 'Contact'){
            masterRecordcontactId = masterRecord.get('Id')+'';
        }
        if(sobjectNameOriginal == 'PersonAccount'){
            Id masterRecordId=  masterRecord.get('Id')+'';
            masterRecordcontactId = [select personcontactId from account where id = :masterRecordId][0].get('personcontactId')+'';
        }
        system.debug('masterRecordcontactId:'+masterRecordcontactId);
   
 
        //get list of campaigns that will be deleted on merge
        list<campaignmember> oldcampaignmembers = database.query('SELECT '+selectfields+' From CampaignMember WHERE contactid = \''+masterRecordcontactId+'\'');
        system.debug('oldcampaignmembers:'+oldcampaignmembers);
        
    
        
        
    //Get contact id of contacts that will be merged
    ID mergecontactId = null;
        if(sobjectNameOriginal == 'Contact'){
           mergecontactId = mergedRecord.get('Id')+'';
        }
        if(sobjectNameOriginal == 'PersonAccount'){
            Id  mergedRecordId = mergedRecord.get('Id')+'';
            system.debug('masterrecordId: '+mergedRecordId);
            mergecontactId = [select personcontactId from account where id = :mergedRecordId][0].get('personcontactId')+'';
        }
        system.debug('mergecontactId: '+mergecontactId);
        
        
        
        
        //Get campaign member ids of the newest campaign member which will be the master
    list<campaignmember> newcampaignmembers = database.query('SELECT isdeleted,'+selectfields+ ' From CampaignMember WHERE contactid = \''+mergecontactId+'\' ');
        system.debug('newcampaignmembers:  '+newcampaignmembers);
        
        
        
        
        //Loop through each campaign member with the same campaignid, all should be the same contact. So if there is two with the same campaignid then they can go together
        
    //list to save results in
    list <campaignmember> campaignmemberstoupdate = new list <campaignmember>();
        
        //convert old campaigns to map so can reference values
        Map<Id,sobject> OldvaluesMap = new Map<Id,sobject>();
        for (CampaignMember CM : Oldcampaignmembers) {
            OldvaluesMap.put(CM.CampaignId, CM);
        }
        //system.debug('OldvaluesMap '+OldvaluesMap);
        
        //loop all campaigns that the new one has 
        for (CampaignMember eachNewCM : newcampaignmembers) {
            //system.debug('eachNewCM: '+eachNewCM);
            
            //if in old map:
            if(OldvaluesMap.get(eachNewCM.CampaignId)!=null){
                //loop all concerns per campaign
                for (MergeConcern__mdt eachConcern : concernscampaignmembers) {                    
                    //if no value or overriddern 
                    if ( (eachConcern.IsForceOverwrite__c  || eachNewCM.get(eachConcern.FieldName__c) == null)  
                         && OldvaluesMap.get(eachNewCM.CampaignId).get(eachConcern.FieldName__c) != null
                       ){
                        // Keep the value from the old record
                        eachNewCM.put( eachConcern.FieldName__c,  OldvaluesMap.get(eachNewCM.CampaignId).get(eachConcern.FieldName__c));
                    }
                   
                }
            campaignmemberstoupdate.add(eachNewCM);
            }

        }
        system.debug('campaignmemberstoupdate: '+campaignmemberstoupdate);
        
        //update all campaign members 
        if(campaignmemberstoupdate.size()>0){
            system.debug('campaignmembers updated');
          update campaignmemberstoupdate;
        }
    
    
    
    
    }













    

    /**
     * Given a list of records, assume that the first record is the master
     * and that all subsequent records are duplicates that should be merged
     * into the master record. With this list, perform the necessary merges.
     *
     * @param records
     */
    public void mergeMany(List<Id> recordIds) {

        // Get a map of matching records, so we can faithfully recreate
        // the list of Sobject records in the necessary order.
        // This means we do not assume that a query will return records
        // in the same order as what's passed to the IN operator.
        Map<Id, Sobject> recordMap = new Map<Id, Sobject>(
                Database.query(this.getQuery()));

        // Recreate the list of Sobject records in order, then merge away
        List<Sobject> records = new List<Sobject>();

        for (Id eachId : recordIds) {
            records.add(recordMap.get(eachId));
        }

        this.mergeMany(records);
    }

    /**
     * Given a list of records, assume that the first record is the master
     * and that all subsequent records are duplicates that should be merged
     * into the master record. With this list, perform the necessary merges.
     *
     * @param records
     */
    public void mergeMany(List<Sobject> records) {
        Sobject masterRecord = records.remove(0);
        for (Sobject eachRecord : records) {
            this.mergeOne(masterRecord, eachRecord);
        }
    }

    /**
     * Given a list of lists, assume that each sublist is a list of records
     * that should be processed by the overloaded `mergeMany` method.
     * Perform all the necessary merges.
     *
     * @param recordLists
     */
    public void mergeMany(List<List<Id>> recordIdLists) {
        for (List<Id> eachList : recordIdLists) {
            this.mergeMany(eachList);
        }
    }

    /**
     * Given a list of lists, assume that each sublist is a list of records
     * that should be processed by the overloaded `mergeMany` method.
     * Perform all the necessary merges.
     *
     * @param recordLists
     */
    public void mergeMany(List<List<Sobject>> recordLists) {
        for (List<Sobject> eachList : recordLists) {
            this.mergeMany(eachList);
        }
    }

    /**
     * @param sobjectName
     *
     * @return an instance of the service
     */
    public static MergeService getInstance(String sobjectName) {
        if (!instancesByName.containsKey(sobjectName)) {
            instancesByName.put(sobjectName, new MergeService(sobjectName));
        }

        return instancesByName.get(sobjectName);
    }

    private Type getSobjectListType() {
        return Type.forName('List<' + this.sobjectName + '>');
    }
}
