#define _DARWIN_C_SOURCE
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>

/* Dedicated read-only raw-disk broker. No shell, arbitrary files, or writes. */
static int read_line(int fd, char *buf, size_t cap) {
    size_t i=0;
    while (i+1<cap) {
        char c;
        ssize_t n=read(fd,&c,1);
        if (n<=0) return -1;
        if (c=='\n') {buf[i]=0;return 0;}
        if ((unsigned char)c<32 || (unsigned char)c>126) return -1;
        buf[i++]=c;
    }
    return -1;
}
static int write_all(int fd, const void *data, size_t len) {
    const char *p=data;
    while(len) {ssize_t n=write(fd,p,len);if(n<0 && errno==EINTR)continue;if(n<=0)return -1;p+=n;len-=n;}
    return 0;
}
static void fail(int fd, const char *message) {
    char buf[200]; snprintf(buf,sizeof(buf),"ERR %.160s\n",message);write_all(fd,buf,strlen(buf));
}
static int external_partition(const char *path) {
    unsigned disk=0, part=0; char extra=0;
    if(sscanf(path,"/dev/rdisk%us%u%c",&disk,&part,&extra)!=2 || part==0)return 0;
    char target[48];snprintf(target,sizeof(target),"disk%us%u",disk,part);
    char parent[48];snprintf(parent,sizeof(parent),"/dev/disk%u ",disk);
    FILE *f=popen("/usr/sbin/diskutil list external","r");
    if(!f)return 0;
    char line[1024];int in_parent=0,found=0;
    while(fgets(line,sizeof(line),f)) {
        if(strncmp(line,"/dev/disk",9)==0) {
            in_parent=strncmp(line,parent,strlen(parent))==0 && strstr(line,"external")!=NULL;
            continue;
        }
        if(!in_parent)continue;
        char *p=strstr(line,target);
        if(p && (p==line || p[-1]==' ' || p[-1]=='\t') && (p[strlen(target)]=='\n' || p[strlen(target)]=='\r' || p[strlen(target)]=='\0')) {found=1;break;}
    }
    pclose(f);return found;
}
static void serve(int conn) {
    char line[256];int diskfd=-1;
    if(read_line(conn,line,sizeof(line))!=0 || strncmp(line,"OPEN ",5)!=0) {fail(conn,"Expected OPEN");return;}
    const char *path=line+5;
    if(!external_partition(path)) {fail(conn,"Not a verified external partition");return;}
    diskfd=open(path,O_RDONLY|O_CLOEXEC|O_NONBLOCK);
    if(diskfd<0) {fail(conn,strerror(errno));return;}
    write_all(conn,"OK\n",3);
    char *block=malloc(1024*1024);
    if(!block) {close(diskfd);return;}
    while(read_line(conn,line,sizeof(line))==0) {
        if(strcmp(line,"CLOSE")==0)break;
        unsigned long long off=0;unsigned len=0;char extra=0;
        if(sscanf(line,"READ %llu %u%c",&off,&len,&extra)!=2 || len==0 || len>1024*1024 || off>INT64_MAX || off+len<off || off+len>INT64_MAX) {fail(conn,"Invalid read request");break;}
        ssize_t n=pread(diskfd,block,len,(off_t)off);
        if(n<0) {fail(conn,strerror(errno));break;}
        char head[64];snprintf(head,sizeof(head),"OK %zd\n",n);
        if(write_all(conn,head,strlen(head)) || write_all(conn,block,(size_t)n))break;
    }
    free(block);close(diskfd);
}
int main(int argc,char **argv) {
    if(argc!=2 || geteuid()!=0) {fprintf(stderr,"Must run as root with a user UID\n");return 1;}
    char *end=NULL;unsigned long uidnum=strtoul(argv[1],&end,10);
    if(!end || *end || uidnum<500 || uidnum>UINT32_MAX) return 1;
    char path[108];snprintf(path,sizeof(path),"/var/run/cooyeye-importer-%lu.sock",uidnum);
    signal(SIGPIPE,SIG_IGN);
    int s=socket(AF_UNIX,SOCK_STREAM,0);if(s<0)return 1;
    struct sockaddr_un addr={0};addr.sun_family=AF_UNIX;strncpy(addr.sun_path,path,sizeof(addr.sun_path)-1);
    unlink(path);mode_t old=umask(077);
    if(bind(s,(struct sockaddr *)&addr,sizeof(addr))!=0)return 1;
    umask(old);
    if(chown(path,(uid_t)uidnum,0)!=0 || chmod(path,0600)!=0 || listen(s,4)!=0)return 1;
    while(1) {
        int c=accept(s,NULL,NULL);if(c<0){if(errno==EINTR)continue;break;}
        uid_t peeruid;gid_t peergid;
        if(getpeereid(c,&peeruid,&peergid)==0 && peeruid==(uid_t)uidnum)serve(c);
        close(c);
    }
    close(s);unlink(path);return 1;
}
