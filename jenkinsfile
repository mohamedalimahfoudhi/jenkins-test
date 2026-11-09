   pipeline {
       agent any
       stages {
           stage('Get code from Git') {
               steps {
                   checkout scm
               }
           }
           stage('Show date') {
               steps {
                   sh 'date'
               }
           }
       }
   }
