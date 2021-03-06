//
//  SCPDownload.m
//  macSVG
//
//  Created by Douglas Ward on 8/12/13.
//
//

// adapted from -
//
//  DFSSHWrapper
//
//  Created by Daniel Finneran on 23/10/2011.
//  Copyright 2011 Home. All rights reserved.
//
// and libssh2 - http://libssh2.org

#import "SCPDownload.h"
#import "DFSSHServer.h"
#include "libssh2_config.h"
#include "libssh2.h"

#ifdef HAVE_WINSOCK2_H
# include <winsock2.h>
#endif
#ifdef HAVE_SYS_SOCKET_H
# include <sys/socket.h>
#endif
#ifdef HAVE_NETINET_IN_H
# include <netinet/in.h>
#endif
# ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif
#ifdef HAVE_ARPA_INET_H
# include <arpa/inet.h>
#endif
#ifdef HAVE_SYS_TIME_H
# include <sys/time.h>
#endif

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <ctype.h>

@implementation SCPDownload


static int waitsocket(int socket_fd, LIBSSH2_SESSION *session)
{
    NSLog(@"waitsocket");
    struct timeval timeout;
    int rc;
    fd_set fd;
    fd_set *writefd = NULL;
    fd_set *readfd = NULL;
    int dir;

    timeout.tv_sec = 10;
    timeout.tv_usec = 0;

    FD_ZERO(&fd);

    FD_SET(socket_fd, &fd);

    /* now make sure we wait in the correct direction */
    dir = libssh2_session_block_directions(session);

    if(dir & LIBSSH2_SESSION_BLOCK_INBOUND)
        readfd = &fd;

    if(dir & LIBSSH2_SESSION_BLOCK_OUTBOUND)
        writefd = &fd;

    rc = select(socket_fd + 1, readfd, writefd, NULL, &timeout);

    return rc;
}



- (NSData *)execSCPDownloadHostaddr:(NSString *)hostaddrString user:(NSString *)usernameString password:(NSString *)passwordString
        scppath:(NSString *)scppathString  sshError:(NSError **)sshError
{
    unsigned long hostaddr;
    //int sock, i, auth_pw = 1;
    int sock, auth_pw = 1;
    struct sockaddr_in sin;
    const char *fingerprint;
    LIBSSH2_SESSION *session;
    LIBSSH2_CHANNEL *channel;
    const char *username="username";
    const char *password="password";
    const char *scppath="/tmp/TEST";
    struct stat fileinfo;
    int rc;
    off_t got=0;


#ifdef WIN32
    WSADATA wsadata;

    WSAStartup(MAKEWORD(2,0), &wsadata);
#endif

    hostaddr = inet_addr([hostaddrString cStringUsingEncoding:NSASCIIStringEncoding]);
    username = [usernameString cStringUsingEncoding:NSASCIIStringEncoding];
    password = [passwordString cStringUsingEncoding:NSASCIIStringEncoding];
    scppath = [scppathString cStringUsingEncoding:NSASCIIStringEncoding];
    BOOL downloadFailed = NO;
    
    NSMutableData * fileData = [NSMutableData data];

/*
    if (argc > 1) {
        hostaddr = inet_addr(argv[1]);
    } else {
        hostaddr = htonl(0x7F000001);
    }
    if (argc > 2) {
        username = argv[2];
    }
    if (argc > 3) {
        password = argv[3];
    }
    if (argc > 4) {
        scppath = argv[4];
    }
*/

    rc = libssh2_init (0);
    if (rc != 0) {
        fprintf (stderr, "libssh2 initialization failed (%d)\n", rc);
        //return 1;
        return NULL;
    }

    /* Ultra basic "connect to port 22 on localhost"
     * Your code is responsible for creating the socket establishing the
     * connection
     */
    sock = socket(AF_INET, SOCK_STREAM, 0);

    sin.sin_family = AF_INET;
    sin.sin_port = htons(22);
    sin.sin_addr.s_addr = (in_addr_t)hostaddr;
    if (connect(sock, (struct sockaddr*)(&sin),
            sizeof(struct sockaddr_in)) != 0) {
        fprintf(stderr, "failed to connect!\n");
        //return -1;
        return NULL;
    }

    /* Create a session instance
     */
    session = libssh2_session_init();
    if(!session)
        //return -1;
        return NULL;



    /* Since we have set non-blocking, tell libssh2 we are non-blocking */
    libssh2_session_set_blocking(session, 0);

    /* ... start it up. This will trade welcome banners, exchange keys,
     * and setup crypto, compression, and MAC layers
     */
    while ((rc = libssh2_session_handshake(session, sock))
           == LIBSSH2_ERROR_EAGAIN);
    if(rc) {
        NSString * errorString = [NSString stringWithFormat:@"Failure setting blocking SSH session (%d)", rc];
        *sshError = [NSError errorWithDomain:errorString code:4 userInfo:NULL];
        goto finalExit;
    }


    /* At this point we havn't yet authenticated.  The first thing to do
     * is check the hostkey's fingerprint against our known hosts Your app
     * may have it hard coded, may go to a file, may present it to the
     * user, that's your call
     */
    fingerprint = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA1);
    
    /*
    fprintf(stderr, "Fingerprint: ");
    for(i = 0; i < 20; i++) {
        fprintf(stderr, "%02X ", (unsigned char)fingerprint[i]);
    }
    fprintf(stderr, "\n");
    */

    if (auth_pw)
    {
        /* We could authenticate via password */
        while ((rc = libssh2_userauth_password(session, username, password)) ==
               LIBSSH2_ERROR_EAGAIN);
        if (rc)
        {
            fprintf(stderr, "Authentication by password failed.\n");
            NSString * errorString = [NSString stringWithFormat:@"SSH authentication by password failed"];
            *sshError = [NSError errorWithDomain:errorString code:6 userInfo:NULL];
            goto shutdown;
        }
    }
    else
    {
        /* Or by public key */
        while ((rc = libssh2_userauth_publickey_fromfile(session, username,
                "/home/username/"
                ".ssh/id_rsa.pub",
                "/home/username/"
                ".ssh/id_rsa",
                password)) == LIBSSH2_ERROR_EAGAIN);
        if (rc)
        {
            fprintf(stderr, "\tAuthentication by public key failed\n");
            NSString * errorString = [NSString stringWithFormat:@"SSH authentication by public key failed"];
            *sshError = [NSError errorWithDomain:errorString code:7 userInfo:NULL];
            goto shutdown;
        }
    }

    /*
    // Request a file via SCP
    channel = libssh2_scp_recv(session, scppath, &fileinfo);

    if (!channel) {
        fprintf(stderr, "Unable to open a session: %d\n",
                libssh2_session_last_errno(session));
        goto shutdown;
    }
    */



    do {
        channel = libssh2_scp_recv(session, scppath, &fileinfo);

        if ((!channel) && (libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN))
        {
            char * errorMsg = NULL;
            int errorMsgLength = 0;
            int want_buf = 0;
            int errorInt = libssh2_session_last_error(session, &errorMsg,
                    &errorMsgLength, want_buf);
            NSString * sshErrorString = @(errorMsg);
            
            NSLog(@"Unable to open SSH session for SCP: %@, %d",
                    sshErrorString, errorInt);
            
            NSString * errorString = [NSString stringWithFormat:@"Unable to open SSH channel for SCP: %@, %d",
                    sshErrorString, libssh2_session_last_errno(session)];
            *sshError = [NSError errorWithDomain:errorString code:8 userInfo:NULL];
            goto shutdown;
        }
    } while (!channel);





    while(got < fileinfo.st_size) {
        char mem[1024];
        //int amount=sizeof(mem);
        long long amount=sizeof(mem);

        if((fileinfo.st_size -got) < amount) {
            amount = fileinfo.st_size -got;
        }

        //rc = libssh2_channel_read(channel, mem, amount);
        
        //while ((rc = libssh2_channel_read(channel, mem, amount)) == LIBSSH2_ERROR_EAGAIN)
        while ((rc = (int)libssh2_channel_read(channel, mem, amount)) == LIBSSH2_ERROR_EAGAIN)
        {
            waitsocket(sock, session);
        }

        if(rc > 0)
        {
            //write(1, mem, rc);    // dsward disable data write
            
            //[fileData appendBytes:&mem length:amount];  // dsward accumulate data here
            [fileData appendBytes:&mem length:rc];  // dsward accumulate data here
        }
        else if(rc < 0)
        {
            fprintf(stderr, "libssh2_channel_read() failed: %d\n", rc);
            NSString * errorString = [NSString stringWithFormat:@"libssh2_channel_read failed"];
            *sshError = [NSError errorWithDomain:errorString code:9 userInfo:NULL];
            downloadFailed = YES;
            break;
        }
        
        got += rc;
    }

    libssh2_channel_free(channel);
    
    channel = NULL;

 shutdown:

    libssh2_session_disconnect(session, "Normal Shutdown");
    
    libssh2_session_free(session);

#ifdef WIN32
    closesocket(sock);
#else
    close(sock);
#endif
    //fprintf(stderr, "all done\n");
    
    if (downloadFailed == YES)
    {
        fileData = NULL;
    }

finalExit:

    libssh2_exit();

    return fileData;
}

@end
